module;

#include "kataglyphis_export.h"

#define ORT_NO_EXCEPTIONS
#include <onnxruntime_cxx_api.h>
#ifdef _WIN32
#include <dml_provider_factory.h>
#endif

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <expected>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <span>
#include <string>
#include <vector>

module kataglyphis.onnx_inference;

import kataglyphis.project_config;
import kataglyphis.log;

namespace kataglyphis::inference {

namespace {

    using InferenceClock = std::chrono::high_resolution_clock;

    // Under ORT_NO_EXCEPTIONS the C++ wrapper aborts on an error status, so every fallible call goes through the C API.
    auto ort_succeeded(OrtStatus *status) -> bool
    {
        if (status == nullptr) { return true; }
        log::error("ONNX Runtime: {}", Ort::GetApi().GetErrorMessage(status));
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
    auto make_float_tensor(const OrtMemoryInfo *memory_info, std::vector<float> &data, const std::vector<int64_t> &dims)
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

    template<typename TypeInfoGetter>
    auto get_named_shape(const std::vector<std::string> &names, const std::string &name, TypeInfoGetter &&get_type_info)
      -> std::expected<TensorShape, OnnxError>
    {
        const auto it = std::ranges::find(names, name);
        if (it == names.end()) { return std::unexpected(OnnxError::OutputNotFound); }

        const auto index = static_cast<std::size_t>(std::distance(names.begin(), it));
        const auto type_info = get_type_info(index);
        return to_tensor_shape(type_info.GetTensorTypeAndShapeInfo().GetShape());
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
    SessionConfig config;
    bool initialized{ false };
    bool profiling_active{ false };

    std::vector<std::string> input_names_cache;
    std::vector<std::string> output_names_cache;
    std::vector<const char *> input_name_ptrs;
    std::vector<const char *> output_name_ptrs;

    void reset()
    {
        initialized = false;
        profiling_active = false;
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

    if (provider == ExecutionProvider::Cuda) {
        OrtCUDAProviderOptions cuda_options{};
        cuda_options.device_id = config.device_id;
        if (!ort_succeeded(api.SessionOptionsAppendExecutionProvider_CUDA(options, &cuda_options))) {
            impl_->reset();
            return std::unexpected(OnnxError::SessionCreationFailed);
        }
    } else if (provider == ExecutionProvider::MigraphX) {
        // Generic options avoid the legacy provider's quoted empty cache path.
        const std::string device_id = std::to_string(config.device_id);
        const std::string memory_limit = std::to_string((std::numeric_limits<std::size_t>::max)());
        const char *keys[] = { "device_id", "migraphx_mem_limit" };
        const char *values[] = { device_id.c_str(), memory_limit.c_str() };
        if (!ort_succeeded(api.SessionOptionsAppendExecutionProvider(options, "MIGraphX", keys, values, 2))) {
            impl_->reset();
            return std::unexpected(OnnxError::SessionCreationFailed);
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
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    std::unique_lock run_lock(impl_->directml_run_mutex, std::defer_lock);
    if (impl_->config.execution_provider == ExecutionProvider::DirectML) { run_lock.lock(); }

    const auto expected_size = input_shape.total_elements();
    if (input_data.size() != expected_size) { return std::unexpected(OnnxError::InvalidInputShape); }

    const auto input_dims = to_ort_dimensions(input_shape);
    std::vector<float> mutable_input(input_data.begin(), input_data.end());

    Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    auto input_tensor = make_float_tensor(memory_info, mutable_input, input_dims);
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

    Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

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

        auto input_tensor = make_float_tensor(memory_info, mutable_data, dims);
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

auto OnnxInferenceEngine::get_input_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    return get_named_shape(impl_->input_names_cache, name, [this](std::size_t index) -> Ort::TypeInfo {
        return impl_->session->GetInputTypeInfo(index);
    });
}

auto OnnxInferenceEngine::get_output_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    return get_named_shape(impl_->output_names_cache, name, [this](std::size_t index) -> Ort::TypeInfo {
        return impl_->session->GetOutputTypeInfo(index);
    });
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
