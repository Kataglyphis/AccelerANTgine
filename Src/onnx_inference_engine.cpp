module;

#include "kataglyphis_export.h"

#define ORT_NO_EXCEPTIONS
#include <onnxruntime_cxx_api.h>
#ifdef _WIN32
#include <dml_provider_factory.h>
#endif

#include "cuda_probe.hpp"
#include "hip_probe.hpp"
#include "ort_plugin.hpp"

#ifndef _WIN32
#include <dlfcn.h>
#endif

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <expected>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

module kataglyphis.onnx_inference;

import kataglyphis.project_config;
import kataglyphis.log;

namespace kataglyphis::inference {

namespace {

    using InferenceClock = std::chrono::high_resolution_clock;

    // Under ORT_NO_EXCEPTIONS the C++ wrapper aborts on an error status, so every fallible call goes through the C API.
    auto ort_succeeded(OrtStatus *status, std::string *message = nullptr) -> bool
    {
        if (status == nullptr) { return true; }
        log::error("ONNX Runtime: {}", Ort::GetApi().GetErrorMessage(status));
        if (message != nullptr) { *message = Ort::GetApi().GetErrorMessage(status); }
        Ort::GetApi().ReleaseStatus(status);
        return false;
    }

    template<typename NameGetter>
    void populate_name_cache(std::size_t count,
      std::vector<std::string> &name_cache,
      std::vector<const char *> &name_ptrs,
      NameGetter &&get_name)
    {
        name_cache.clear();
        name_ptrs.clear();
        name_cache.reserve(count);

        for (std::size_t i = 0; i < count; ++i) {
            auto name = get_name(i);
            name_cache.emplace_back(name.get());
        }

        name_ptrs.reserve(name_cache.size());
        for (const auto &name : name_cache) { name_ptrs.push_back(name.c_str()); }
    }

    auto to_ort_dimensions(const TensorShape &shape) -> std::vector<int64_t>
    {
        std::vector<int64_t> dims;
        dims.reserve(shape.dimensions.size());
        for (const auto dim : shape.dimensions) { dims.push_back(static_cast<int64_t>(dim)); }
        return dims;
    }

    auto to_tensor_shape(std::span<const int64_t> dims) -> TensorShape
    {
        TensorShape shape;
        shape.dimensions.reserve(dims.size());
        for (const auto dim : dims) { shape.dimensions.push_back(static_cast<std::size_t>(dim)); }
        return shape;
    }

    auto to_tensor_data(const Ort::Value &tensor) -> std::expected<TensorData, OnnxError>
    {
        const OrtApi &api = Ort::GetApi();
        ONNXType value_type{};
        if (!ort_succeeded(api.GetValueType(tensor, &value_type)) || value_type != ONNX_TYPE_TENSOR) {
            return std::unexpected(OnnxError::InvalidOutputType);
        }
        OrtTensorTypeAndShapeInfo *raw_info = nullptr;
        if (!ort_succeeded(api.GetTensorTypeAndShape(tensor, &raw_info))) {
            return std::unexpected(OnnxError::InvalidOutputType);
        }
        const Ort::TensorTypeAndShapeInfo type_info{ raw_info };
        ONNXTensorElementDataType element_type{};
        if (!ort_succeeded(api.GetTensorElementType(type_info, &element_type))
            || element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
            return std::unexpected(OnnxError::InvalidOutputType);
        }
        std::size_t rank = 0;
        if (!ort_succeeded(api.GetDimensionsCount(type_info, &rank))) {
            return std::unexpected(OnnxError::InvalidOutputShape);
        }
        std::vector<int64_t> shape(rank);
        std::size_t total_elements = 0;
        if (!ort_succeeded(api.GetDimensions(type_info, shape.data(), rank))
            || std::ranges::any_of(shape, [](int64_t dim) { return dim < 0; })
            || !ort_succeeded(api.GetTensorShapeElementCount(type_info, &total_elements))) {
            return std::unexpected(OnnxError::InvalidOutputShape);
        }
        TensorData tensor_data;
        tensor_data.shape = to_tensor_shape(shape);
        void *raw_data = nullptr;
        if (!ort_succeeded(api.GetTensorMutableData(tensor, &raw_data))) {
            return std::unexpected(OnnxError::OutputAllocationFailed);
        }
        if (total_elements != 0) {
            if (raw_data == nullptr) { return std::unexpected(OnnxError::OutputAllocationFailed); }
            const auto *data = static_cast<const float *>(raw_data);
            tensor_data.data.assign(data, data + total_elements);
        }
        return tensor_data;
    }

    auto make_inference_result(const std::vector<Ort::Value> &output_tensors,
      const InferenceClock::time_point start_time,
      const InferenceClock::time_point end_time) -> std::expected<InferenceResult, OnnxError>
    {
        InferenceResult result;
        result.inference_time_ms = std::chrono::duration<double, std::milli>(end_time - start_time).count();
        result.outputs.reserve(output_tensors.size());

        for (const auto &tensor : output_tensors) {
            auto output = to_tensor_data(tensor);
            if (!output) { return std::unexpected(output.error()); }
            result.outputs.push_back(std::move(*output));
        }

        return result;
    }

    // ORT only borrows the buffer, so it must outlive the Run that reads it.
    auto make_float_tensor(const OrtMemoryInfo *memory_info, std::span<float> data, const std::vector<int64_t> &dims)
      -> std::expected<Ort::Value, OnnxError>
    {
        OrtValue *value = nullptr;
        if (!ort_succeeded(Ort::GetApi().CreateTensorWithDataAsOrtValue(memory_info,
              data.data(),
              data.size() * sizeof(float),
              dims.data(),
              dims.size(),
              ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
              &value))) {
            return std::unexpected(OnnxError::InputAllocationFailed);
        }
        return Ort::Value{ value };
    }

    auto run_session(OrtSession *session,
      const std::vector<const char *> &input_names,
      const std::vector<Ort::Value> &inputs,
      const std::vector<const char *> &output_names) -> std::expected<std::vector<Ort::Value>, OnnxError>
    {
        std::vector<const OrtValue *> input_values;
        input_values.reserve(inputs.size());
        for (const auto &input : inputs) { input_values.push_back(input); }

        std::vector<OrtValue *> outputs(output_names.size(), nullptr);
        const bool succeeded = ort_succeeded(Ort::GetApi().Run(session,
          nullptr,
          input_names.data(),
          input_values.data(),
          input_values.size(),
          output_names.data(),
          output_names.size(),
          outputs.data()));

        std::vector<Ort::Value> owned;
        owned.reserve(outputs.size());
        for (auto *output : outputs) {
            if (output != nullptr) { owned.emplace_back(output); }
        }
        if (!succeeded || owned.size() != output_names.size()) { return std::unexpected(OnnxError::InferenceFailed); }
        return owned;
    }

    // ONNX Runtime's message when one kernel will not run on the card; empty when it ran.
    auto run_one_cuda_kernel(OrtEnv *env, int device_id) -> std::string
    {
        const OrtApi &api = Ort::GetApi();
        std::string error;
        Ort::SessionOptions options;
        OrtCUDAProviderOptions cuda_options{};
        cuda_options.device_id = device_id;
        OrtSession *raw_session = nullptr;
        // The reason below says it better than ONNX Runtime's red line about a failed node.
        if (!ort_succeeded(api.SetSessionLogSeverityLevel(options, ORT_LOGGING_LEVEL_FATAL), &error)
            || !ort_succeeded(api.SessionOptionsAppendExecutionProvider_CUDA(options, &cuda_options), &error)
            || !ort_succeeded(
              api.CreateSessionFromArray(
                env, cuda_probe::one_kernel().data(), cuda_probe::one_kernel().size(), options, &raw_session),
              &error)) {
            return error;
        }
        const Ort::Session session{ raw_session };
        Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<float> input{ -1.0F };
        auto tensor = make_float_tensor(memory_info, input, { 1 });
        if (!tensor) { return "the one-kernel input could not be allocated"; }
        const char *input_name = "x";
        const char *output_name = "y";
        const OrtValue *input_value = *tensor;
        OrtValue *output = nullptr;
        ort_succeeded(api.Run(raw_session, nullptr, &input_name, &input_value, 1, &output_name, 1, &output), &error);
        if (output != nullptr) { api.ReleaseValue(output); }
        return error;
    }

    // The name GetAvailableProviders reports for a runtime built with the provider; a plugin has a table row.
    auto provider_name(ExecutionProvider provider) -> std::string_view
    {
        switch (provider) {
        case ExecutionProvider::Cpu:
            return "CPUExecutionProvider";
        case ExecutionProvider::Cuda:
            return "CUDAExecutionProvider";
        case ExecutionProvider::MigraphX:
            break;
        case ExecutionProvider::DirectML:
            return "DmlExecutionProvider";
        case ExecutionProvider::Xnnpack:
            return "XnnpackExecutionProvider";
        case ExecutionProvider::Dnnl:
            return "DnnlExecutionProvider";
        }
        return {};
    }

    auto available_by_name(std::string_view name) -> bool
    {
        const OrtApi &api = Ort::GetApi();
        char **providers = nullptr;
        int count = 0;
        if (!ort_succeeded(api.GetAvailableProviders(&providers, &count))) { return false; }
        bool found = false;
        for (int i = 0; i < count; ++i) { found = found || name == providers[i]; }
        return ort_succeeded(api.ReleaseAvailableProviders(providers, count)) && found;
    }

    // With default options an append fails only when the provider cannot load, so that is ProviderUnavailable too.
    auto append_cpu_provider(OrtSessionOptions *options,
      ExecutionProvider provider,
      int intra_op_num_threads,
      std::string &reason) -> std::expected<void, OnnxError>
    {
        const OrtApi &api = Ort::GetApi();
        if (provider == ExecutionProvider::Xnnpack) {
            const std::string threads = std::to_string(intra_op_num_threads);
            const char *keys[] = { "intra_op_num_threads" };
            const char *values[] = { threads.c_str() };
            if (!ort_succeeded(
                  api.SessionOptionsAppendExecutionProvider(options, "XNNPACK", keys, values, 1), &reason)) {
                return std::unexpected(OnnxError::ProviderUnavailable);
            }
            return {};
        }
        OrtDnnlProviderOptions *dnnl = nullptr;
        if (!ort_succeeded(api.CreateDnnlProviderOptions(&dnnl), &reason)) {
            return std::unexpected(OnnxError::ProviderUnavailable);
        }
        const bool appended = ort_succeeded(api.SessionOptionsAppendExecutionProvider_Dnnl(options, dnnl), &reason);
        api.ReleaseDnnlProviderOptions(dnnl);
        if (!appended) { return std::unexpected(OnnxError::ProviderUnavailable); }
        return {};
    }

    // One lock for register, list and append: ONNX Runtime hands out its own device array, which a registration grows.
    struct PluginState
    {
        std::mutex mutex;
        ort_plugin::Registered registered;
    };

    auto plugin_state() -> PluginState &
    {
        static PluginState state;
        return state;
    }

    // The plugin's module, or what was looked for.
    auto plugin_module(const ort_plugin::Plugin &plugin) -> std::expected<std::filesystem::path, std::string>
    {
#ifdef _WIN32
        return std::unexpected(std::string(plugin.name) + " is loaded as a plugin on Linux only");
#else
        const char *root = std::getenv(plugin.root_variable);
        const std::string_view root_value = root == nullptr ? std::string_view{} : std::string_view{ root };
        Dl_info ort{};
        std::filesystem::path ort_directory;
        // ONNX Runtime's own API table lies inside its library, wherever the loader took that from.
        if (::dladdr(&Ort::GetApi(), &ort) != 0 && ort.dli_fname != nullptr) {
            const auto loaded_from = std::filesystem::path(ort.dli_fname).parent_path();
            std::error_code unresolved;
            ort_directory = std::filesystem::canonical(loaded_from, unresolved);
            if (unresolved) { ort_directory = loaded_from; }
        }
        const auto candidates = ort_plugin::module_candidates(plugin, root_value, ort_directory);
        auto library = ort_plugin::first_file(candidates);
        if (library.empty()) {
            return std::unexpected(ort_plugin::missing_module_reason(plugin, root_value, candidates));
        }
        return library;
#endif
    }

    struct OfferedDevices
    {
        const OrtEpDevice *chosen{ nullptr };
        std::size_t count{ 0 };
    };

    // The devices listed under a provider name, with the one at index; the caller holds the plugin lock.
    auto offered_devices(OrtEnv *env, std::string_view name, int index) -> std::expected<OfferedDevices, std::string>
    {
        const OrtApi &api = Ort::GetApi();
        const OrtEpDevice *const *devices = nullptr;
        std::size_t count = 0;
        std::string reason;
        if (!ort_succeeded(api.GetEpDevices(env, &devices, &count), &reason)) { return std::unexpected(reason); }
        OfferedDevices offered;
        for (const OrtEpDevice *device : std::span(devices, count)) {
            const char *ep_name = api.EpDevice_EpName(device);
            if (ep_name == nullptr || name != ep_name) { continue; }
            if (std::cmp_equal(offered.count, index)) { offered.chosen = device; }
            ++offered.count;
        }
        return offered;
    }

    // The registration ends with the process's last environment, so one reference is never released.
    auto register_plugin(OrtEnv *env,
      const ort_plugin::Plugin &plugin,
      const std::filesystem::path &library,
      std::string &reason) -> bool
    {
        const OrtApi &api = Ort::GetApi();
        return plugin_state().registered.ensure(plugin.name, [&] {
            OrtEnv *kept = nullptr;
            if (!ort_succeeded(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "KataglyphisOnnxRuntime", &kept), &reason)) {
                return false;
            }
            // Another library of this process may hold the name already, and ONNX Runtime refuses it a second time.
            const auto held = offered_devices(env, plugin.name, 0);
            if ((held && held->count > 0)
                || ort_succeeded(api.RegisterExecutionProviderLibrary(env, plugin.name, library.c_str()), &reason)) {
                return true;
            }
            api.ReleaseEnv(kept);
            return false;
        });
    }

    // Empty when the plugin's device is on options; else what was looked for and why it could not be had.
    auto append_plugin(OrtEnv *env,
      OrtSessionOptions *options,
      [[maybe_unused]] ExecutionProvider provider,
      const ort_plugin::Plugin &plugin,
      int device_id) -> std::string
    {
        const std::string name = plugin.name;
        const auto library = plugin_module(plugin);
        if (!library) { return library.error(); }
#ifndef _WIN32
        // AMD's module calls HIP as it registers, so the copy that may never return is tried first.
        const auto copy = [device_id] { hip_probe::copy_to_device(hip_probe::runtime, device_id); };
        if (provider == ExecutionProvider::MigraphX && !hip_probe::answers_within(hip_probe::answer_limit, copy)) {
            return name + " cannot run: a copy to the AMD GPU took over 30 seconds. The cpu device runs on the CPU";
        }
#endif
        const OrtApi &api = Ort::GetApi();
        const std::scoped_lock lock(plugin_state().mutex);
        std::string reason;
        if (!register_plugin(env, plugin, *library, reason)) {
            return name + " failed to register " + library->string() + ": " + reason;
        }
        const auto offered = offered_devices(env, name, device_id);
        if (!offered) {
            return name + " registered " + library->string() + ", but its devices cannot be listed: " + offered.error();
        }
        if (offered->chosen == nullptr) {
            return name + " registered " + library->string() + ", which offers " + std::to_string(offered->count)
                   + " device(s), so device " + std::to_string(device_id) + " does not exist";
        }
        const auto settings = ort_plugin::device_options(device_id);
        std::vector<const char *> keys;
        std::vector<const char *> values;
        for (const auto &[key, value] : settings) {
            keys.push_back(key.c_str());
            values.push_back(value.c_str());
        }
        // AMD's module refuses more than one device and takes the card from the option, so both name the same card.
        if (!ort_succeeded(api.SessionOptionsAppendExecutionProvider_V2(
                             options, env, &offered->chosen, 1, keys.data(), values.data(), keys.size()),
              &reason)) {
            return name + " from " + library->string() + " was refused: " + reason;
        }
        return {};
    }

    // The C API, as for a fallible call everywhere here: the wrapper aborts under ORT_NO_EXCEPTIONS on a non-tensor.
    template<typename TypeInfoGetter>
    auto get_named_shape(const std::vector<std::string> &names,
      const std::string &name,
      OnnxError not_a_tensor,
      TypeInfoGetter &&get_type_info) -> std::expected<DeclaredShape, OnnxError>
    {
        const auto it = std::ranges::find(names, name);
        if (it == names.end()) { return std::unexpected(OnnxError::OutputNotFound); }

        const OrtApi &api = Ort::GetApi();
        OrtTypeInfo *raw_type_info = nullptr;
        if (!ort_succeeded(get_type_info(static_cast<std::size_t>(std::distance(names.begin(), it)), &raw_type_info))) {
            return std::unexpected(not_a_tensor);
        }
        const Ort::TypeInfo type_info{ raw_type_info };
        const OrtTensorTypeAndShapeInfo *tensor_info = nullptr;
        if (!ort_succeeded(api.CastTypeInfoToTensorInfo(type_info, &tensor_info)) || tensor_info == nullptr) {
            return std::unexpected(not_a_tensor);
        }
        std::size_t rank = 0;
        if (!ort_succeeded(api.GetDimensionsCount(tensor_info, &rank))) { return std::unexpected(not_a_tensor); }
        std::vector<int64_t> dims(rank);
        if (!ort_succeeded(api.GetDimensions(tensor_info, dims.data(), rank))) { return std::unexpected(not_a_tensor); }
        DeclaredShape shape;
        shape.dimensions.reserve(rank);
        for (const auto dim : dims) {
            shape.dimensions.push_back(dim < 0 ? std::nullopt : std::optional{ static_cast<std::size_t>(dim) });
        }
        return shape;
    }

}// namespace

struct OnnxInferenceEngine::Impl
{
    // DirectML requires Run calls on the same session to be serialized.
    mutable std::shared_mutex mutex;
    mutable std::mutex directml_run_mutex;
    std::unique_ptr<Ort::Env> env;
    std::unique_ptr<Ort::Session> session;
    std::unique_ptr<Ort::SessionOptions> session_options;
    Ort::AllocatorWithDefaultOptions allocator;
    // Made once in initialize; every run borrows it instead of creating its own.
    Ort::MemoryInfo cpu_memory{ nullptr };
    SessionConfig config;
    bool initialized{ false };
    bool profiling_active{ false };
    int applied_intra_op_num_threads{ 0 };
    std::string provider_error;

    std::vector<std::string> input_names_cache;
    std::vector<std::string> output_names_cache;
    std::vector<const char *> input_name_ptrs;
    std::vector<const char *> output_name_ptrs;

    void reset()
    {
        initialized = false;
        profiling_active = false;
        applied_intra_op_num_threads = 0;
        provider_error.clear();
        input_name_ptrs.clear();
        output_name_ptrs.clear();
        input_names_cache.clear();
        output_names_cache.clear();
        session.reset();
        session_options.reset();
        env.reset();
    }
};

OnnxInferenceEngine::OnnxInferenceEngine() : impl_(std::make_unique<Impl>()) {}

OnnxInferenceEngine::~OnnxInferenceEngine() = default;

OnnxInferenceEngine::OnnxInferenceEngine(OnnxInferenceEngine &&) noexcept = default;

auto OnnxInferenceEngine::operator=(OnnxInferenceEngine &&) noexcept -> OnnxInferenceEngine & = default;

auto OnnxInferenceEngine::initialize(const SessionConfig &config) -> std::expected<void, OnnxError>
{
    const std::unique_lock lock(impl_->mutex);
    // A failed initialisation leaves the engine uninitialised, never with a half-replaced session.
    impl_->reset();
    impl_->config = config;

    if (config.device_id < 0
        || (config.enable_cuda && config.execution_provider != ExecutionProvider::Cpu
            && config.execution_provider != ExecutionProvider::Cuda)) {
        return std::unexpected(OnnxError::SessionCreationFailed);
    }
    const auto provider = config.enable_cuda ? ExecutionProvider::Cuda : config.execution_provider;

    const OrtApi &api = Ort::GetApi();
    impl_->env = std::make_unique<Ort::Env>(OrtLoggingLevel::ORT_LOGGING_LEVEL_WARNING, "KataglyphisOnnxRuntime");
    impl_->session_options = std::make_unique<Ort::SessionOptions>();
    OrtSessionOptions *options = *impl_->session_options;

    if (!config.profiling_prefix.empty()
        && !ort_succeeded(api.EnableProfiling(options, config.profiling_prefix.c_str()))) {
        impl_->reset();
        return std::unexpected(OnnxError::ProfilingFailed);
    }

    const auto execution_mode =
      provider != ExecutionProvider::DirectML && config.execution_mode == ExecutionMode::Parallel ? ORT_PARALLEL
                                                                                                  : ORT_SEQUENTIAL;
    if (!ort_succeeded(api.SetIntraOpNumThreads(options, config.intra_op_num_threads))
        || !ort_succeeded(api.SetInterOpNumThreads(options, config.inter_op_num_threads))
        || !ort_succeeded(api.SetSessionExecutionMode(options, execution_mode))
        || !ort_succeeded(config.enable_memory_pattern && provider != ExecutionProvider::DirectML
                            ? api.EnableMemPattern(options)
                            : api.DisableMemPattern(options))) {
        impl_->reset();
        return std::unexpected(OnnxError::SessionCreationFailed);
    }
    impl_->applied_intra_op_num_threads = config.intra_op_num_threads;

    const ort_plugin::Plugin *plugin = ort_plugin::plugin_for(provider);
    // A provider the runtime lacks is its own error, so a request never runs on plain CPU unnoticed.
    if (provider != ExecutionProvider::Cpu && plugin == nullptr && !provider_available(provider)) {
        impl_->reset();
        impl_->provider_error = std::string(provider_name(provider)) + " is not built into the loaded ONNX Runtime";
        return std::unexpected(OnnxError::ProviderUnavailable);
    }

    if (provider == ExecutionProvider::Xnnpack || provider == ExecutionProvider::Dnnl) {
        std::string reason;
        if (auto appended = append_cpu_provider(options, provider, config.intra_op_num_threads, reason); !appended) {
            impl_->reset();
            impl_->provider_error = std::move(reason);
            return std::unexpected(appended.error());
        }
    } else if (provider == ExecutionProvider::Cuda) {
        const auto reason = cuda_probe::no_kernel_reason(run_one_cuda_kernel(*impl_->env, config.device_id),
          [device = config.device_id] { return cuda_probe::card_on(cuda_probe::driver, device); });
        if (reason) {
            impl_->reset();
            impl_->provider_error = *reason;
            // The demos print only the error code, and this one has a way out.
            kataglyphis::log::error("{}", impl_->provider_error);
            return std::unexpected(OnnxError::ProviderUnavailable);
        }
        OrtCUDAProviderOptions cuda_options{};
        cuda_options.device_id = config.device_id;
        if (!ort_succeeded(api.SessionOptionsAppendExecutionProvider_CUDA(options, &cuda_options))) {
            impl_->reset();
            return std::unexpected(OnnxError::SessionCreationFailed);
        }
    } else if (plugin != nullptr) {
        // No by-name append comes first: a failed one leaves ep.* entries, and AMD's plugin fails on a foreign one.
        auto reason = append_plugin(*impl_->env, options, provider, *plugin, config.device_id);
        if (!reason.empty()) {
            impl_->reset();
            impl_->provider_error = std::move(reason);
            // The demos print only the error code, and this one has a way out.
            kataglyphis::log::error("{}", impl_->provider_error);
            return std::unexpected(OnnxError::ProviderUnavailable);
        }
    } else if (provider == ExecutionProvider::DirectML) {
#ifdef _WIN32
        const void *provider_api = nullptr;
        if (!ort_succeeded(api.GetExecutionProviderApi("DML", ORT_API_VERSION, &provider_api))
            || provider_api == nullptr
            || !ort_succeeded(static_cast<const OrtDmlApi *>(provider_api)
                ->SessionOptionsAppendExecutionProvider_DML(options, config.device_id))) {
#endif
            impl_->reset();
            return std::unexpected(OnnxError::SessionCreationFailed);
#ifdef _WIN32
        }
#endif
    } else if (provider != ExecutionProvider::Cpu) {
        impl_->reset();
        return std::unexpected(OnnxError::SessionCreationFailed);
    }

    OrtSession *session = nullptr;
    if (!ort_succeeded(api.CreateSession(*impl_->env, config.model_path.c_str(), options, &session))) {
        impl_->reset();
        return std::unexpected(OnnxError::ModelLoadFailed);
    }
    impl_->session = std::make_unique<Ort::Session>(session);

    populate_name_cache(impl_->session->GetInputCount(),
      impl_->input_names_cache,
      impl_->input_name_ptrs,
      [this](std::size_t index) -> Ort::AllocatedStringPtr {
          return impl_->session->GetInputNameAllocated(index, impl_->allocator);
      });

    populate_name_cache(impl_->session->GetOutputCount(),
      impl_->output_names_cache,
      impl_->output_name_ptrs,
      [this](std::size_t index) -> Ort::AllocatedStringPtr {
          return impl_->session->GetOutputNameAllocated(index, impl_->allocator);
      });

    impl_->cpu_memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    impl_->initialized = true;
    impl_->profiling_active = !config.profiling_prefix.empty();

    return {};
}

auto OnnxInferenceEngine::is_initialized() const -> bool
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->initialized;
}

auto OnnxInferenceEngine::end_profiling() -> std::expected<std::string, OnnxError>
{
    const std::unique_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }
    if (!impl_->profiling_active) { return std::unexpected(OnnxError::ProfilingNotEnabled); }
    char *filename = nullptr;
    const auto &api = Ort::GetApi();
    if (!ort_succeeded(api.SessionEndProfiling(*impl_->session, impl_->allocator, &filename)) || filename == nullptr) {
        return std::unexpected(OnnxError::ProfilingFailed);
    }
    const std::string result(filename);
    const bool freed = ort_succeeded(api.AllocatorFree(impl_->allocator, filename));
    impl_->profiling_active = false;
    if (!freed) { return std::unexpected(OnnxError::ProfilingFailed); }
    return result;
}

auto OnnxInferenceEngine::run_inference(std::span<const float> input_data,
  const TensorShape &input_shape,
  const std::string &input_name) -> std::expected<InferenceResult, OnnxError>
{
    // ORT takes a mutable pointer, so a read-only caller pays for one copy; a wrong size is refused before it is made.
    if (input_data.size() != input_shape.total_elements()) {
        const std::shared_lock lock(impl_->mutex);
        return std::unexpected(impl_->initialized ? OnnxError::InvalidInputShape : OnnxError::SessionNotInitialized);
    }
    std::vector<float> mutable_input(input_data.begin(), input_data.end());
    return run_inference_in_place(mutable_input, input_shape, input_name);
}

auto OnnxInferenceEngine::run_inference_in_place(std::span<float> input_data,
  const TensorShape &input_shape,
  const std::string &input_name) -> std::expected<InferenceResult, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    std::unique_lock run_lock(impl_->directml_run_mutex, std::defer_lock);
    if (impl_->config.execution_provider == ExecutionProvider::DirectML) { run_lock.lock(); }

    const auto expected_size = input_shape.total_elements();
    if (input_data.size() != expected_size) { return std::unexpected(OnnxError::InvalidInputShape); }

    const auto input_dims = to_ort_dimensions(input_shape);

    auto input_tensor = make_float_tensor(impl_->cpu_memory, input_data, input_dims);
    if (!input_tensor) { return std::unexpected(input_tensor.error()); }

    std::vector<Ort::Value> inputs;
    inputs.push_back(std::move(*input_tensor));

    const auto start_time = InferenceClock::now();

    auto output_tensors = run_session(*impl_->session, { input_name.c_str() }, inputs, impl_->output_name_ptrs);
    if (!output_tensors) { return std::unexpected(output_tensors.error()); }

    return make_inference_result(*output_tensors, start_time, InferenceClock::now());
}

auto OnnxInferenceEngine::run_inference_multi_input(const std::vector<std::pair<std::string, TensorData>> &inputs)
  -> std::expected<InferenceResult, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    std::unique_lock run_lock(impl_->directml_run_mutex, std::defer_lock);
    if (impl_->config.execution_provider == ExecutionProvider::DirectML) { run_lock.lock(); }

    // Ort::Value borrows its buffer, so the copied inputs must outlive the Run.
    std::vector<std::vector<float>> owned_input_data;
    std::vector<std::vector<int64_t>> input_dims_storage;
    std::vector<Ort::Value> input_tensors;
    std::vector<const char *> input_names;

    owned_input_data.reserve(inputs.size());
    input_dims_storage.reserve(inputs.size());
    input_tensors.reserve(inputs.size());
    input_names.reserve(inputs.size());

    for (const auto &[name, tensor_data] : inputs) {
        if (tensor_data.data.size() != tensor_data.shape.total_elements()) {
            return std::unexpected(OnnxError::InvalidInputShape);
        }

        auto &mutable_data = owned_input_data.emplace_back(tensor_data.data.begin(), tensor_data.data.end());
        auto &dims = input_dims_storage.emplace_back(to_ort_dimensions(tensor_data.shape));

        auto input_tensor = make_float_tensor(impl_->cpu_memory, mutable_data, dims);
        if (!input_tensor) { return std::unexpected(input_tensor.error()); }

        input_tensors.push_back(std::move(*input_tensor));
        input_names.push_back(name.c_str());
    }

    const auto start_time = InferenceClock::now();

    auto output_tensors = run_session(*impl_->session, input_names, input_tensors, impl_->output_name_ptrs);
    if (!output_tensors) { return std::unexpected(output_tensors.error()); }

    return make_inference_result(*output_tensors, start_time, InferenceClock::now());
}

auto OnnxInferenceEngine::get_input_names() const -> std::vector<std::string>
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->input_names_cache;
}

auto OnnxInferenceEngine::get_output_names() const -> std::vector<std::string>
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->output_names_cache;
}

auto OnnxInferenceEngine::get_input_shape(const std::string &name) const -> std::expected<DeclaredShape, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    return get_named_shape(impl_->input_names_cache,
      name,
      OnnxError::InvalidInputType,
      [this](std::size_t index, OrtTypeInfo **out) -> OrtStatus * {
          return Ort::GetApi().SessionGetInputTypeInfo(*impl_->session, index, out);
      });
}

auto OnnxInferenceEngine::get_output_shape(const std::string &name) const -> std::expected<DeclaredShape, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    return get_named_shape(impl_->output_names_cache,
      name,
      OnnxError::InvalidOutputType,
      [this](std::size_t index, OrtTypeInfo **out) -> OrtStatus * {
          return Ort::GetApi().SessionGetOutputTypeInfo(*impl_->session, index, out);
      });
}

auto OnnxInferenceEngine::get_custom_metadata(const std::string &key) const -> std::expected<std::string, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }
    const OrtApi &api = Ort::GetApi();
    OrtModelMetadata *metadata = nullptr;
    if (!ort_succeeded(api.SessionGetModelMetadata(*impl_->session, &metadata))) {
        return std::unexpected(OnnxError::ModelLoadFailed);
    }
    char *value = nullptr;
    const bool found =
      ort_succeeded(api.ModelMetadataLookupCustomMetadataMap(metadata, impl_->allocator, key.c_str(), &value));
    api.ReleaseModelMetadata(metadata);
    if (!found) { return std::unexpected(OnnxError::ModelLoadFailed); }
    if (value == nullptr) { return std::string{}; }
    std::string result(value);
    if (!ort_succeeded(api.AllocatorFree(impl_->allocator, value))) {
        return std::unexpected(OnnxError::ModelLoadFailed);
    }
    return result;
}

auto OnnxInferenceEngine::provider_error() const -> std::string
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->provider_error;
}

auto OnnxInferenceEngine::applied_intra_op_num_threads() const -> int
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->applied_intra_op_num_threads;
}

KATAGLYPHIS_CPP_API auto provider_available(ExecutionProvider provider) -> bool
{
    // GetAvailableProviders never lists a plugin, so its module on disk is the answer.
    if (const auto *plugin = ort_plugin::plugin_for(provider)) { return plugin_module(*plugin).has_value(); }
    return available_by_name(provider_name(provider));
}

KATAGLYPHIS_CPP_API auto create_default_session_config(const std::filesystem::path &model_path) -> SessionConfig
{
    SessionConfig config;
    config.model_path = model_path;
    config.intra_op_num_threads = 4;
    config.inter_op_num_threads = 4;
    config.enable_cuda = false;
    config.enable_memory_pattern = true;
    config.execution_mode = ExecutionMode::Sequential;
    return config;
}

}// namespace kataglyphis::inference
