module;

#include "kataglyphis_export.h"

#define ORT_NO_EXCEPTIONS
#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <chrono>
#include <expected>
#include <filesystem>
#include <memory>
#include <span>
#include <string>
#include <vector>

module kataglyphis.onnx_inference;

import kataglyphis.project_config;

namespace kataglyphis::inference {

namespace {

using InferenceClock = std::chrono::high_resolution_clock;

template <typename NameGetter>
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

auto to_tensor_data(const Ort::Value &tensor) -> TensorData
{
    TensorData tensor_data;
    const auto type_info = tensor.GetTensorTypeAndShapeInfo();
    const auto shape = type_info.GetShape();

    tensor_data.shape = to_tensor_shape(shape);

    const auto total_elements = type_info.GetElementCount();
    const auto *tensor_data_ptr = tensor.GetTensorData<float>();

    tensor_data.data.assign(tensor_data_ptr, tensor_data_ptr + total_elements);
    return tensor_data;
}

auto make_inference_result(const std::vector<Ort::Value> &output_tensors,
  const InferenceClock::time_point start_time,
  const InferenceClock::time_point end_time) -> InferenceResult
{
    InferenceResult result;
    result.inference_time_ms = std::chrono::duration<double, std::milli>(end_time - start_time).count();
    result.outputs.reserve(output_tensors.size());

    for (const auto &tensor : output_tensors) { result.outputs.push_back(to_tensor_data(tensor)); }

    return result;
}

template <typename TypeInfoGetter>
auto get_named_shape(const std::vector<std::string> &names, const std::string &name, TypeInfoGetter &&get_type_info)
  -> std::expected<TensorShape, OnnxError>
{
    const auto it = std::ranges::find(names, name);
    if (it == names.end()) { return std::unexpected(OnnxError::OutputNotFound); }

    const auto index = static_cast<std::size_t>(std::distance(names.begin(), it));
    const auto type_info = get_type_info(index);
    return to_tensor_shape(type_info.GetTensorTypeAndShapeInfo().GetShape());
}

}  // namespace

struct OnnxInferenceEngine::Impl
{
    std::unique_ptr<Ort::Env> env;
    std::unique_ptr<Ort::Session> session;
    std::unique_ptr<Ort::SessionOptions> session_options;
    Ort::AllocatorWithDefaultOptions allocator;
    SessionConfig config;
    bool initialized{ false };

    std::vector<std::string> input_names_cache;
    std::vector<std::string> output_names_cache;
    std::vector<const char *> input_name_ptrs;
    std::vector<const char *> output_name_ptrs;
};

OnnxInferenceEngine::OnnxInferenceEngine() : impl_(std::make_unique<Impl>()) {}

OnnxInferenceEngine::~OnnxInferenceEngine() = default;

OnnxInferenceEngine::OnnxInferenceEngine(OnnxInferenceEngine &&) noexcept = default;

auto OnnxInferenceEngine::operator=(OnnxInferenceEngine &&) noexcept -> OnnxInferenceEngine & = default;

auto OnnxInferenceEngine::initialize(const SessionConfig &config) -> std::expected<void, OnnxError>
{
    impl_->config = config;

    impl_->env = std::make_unique<Ort::Env>(OrtLoggingLevel::ORT_LOGGING_LEVEL_WARNING, "KataglyphisOnnxRuntime");

    impl_->session_options = std::make_unique<Ort::SessionOptions>();

    impl_->session_options->SetIntraOpNumThreads(config.intra_op_num_threads);
    impl_->session_options->SetInterOpNumThreads(config.inter_op_num_threads);

    if (config.execution_mode == ExecutionMode::Parallel) {
        impl_->session_options->SetExecutionMode(ORT_PARALLEL);
    } else {
        impl_->session_options->SetExecutionMode(ORT_SEQUENTIAL);
    }

    if (config.enable_memory_pattern) { impl_->session_options->EnableMemPattern(); }

    if (config.enable_cuda) {
        OrtCUDAProviderOptions cuda_options;
        cuda_options.device_id = 0;
        impl_->session_options->AppendExecutionProvider_CUDA(cuda_options);
    }

    impl_->session =
      std::make_unique<Ort::Session>(*impl_->env, config.model_path.c_str(), *impl_->session_options);

    populate_name_cache(impl_->session->GetInputCount(),
      impl_->input_names_cache,
      impl_->input_name_ptrs,
      [this](std::size_t index) -> Ort::AllocatedStringPtr { return impl_->session->GetInputNameAllocated(index, impl_->allocator); });

    populate_name_cache(impl_->session->GetOutputCount(),
      impl_->output_names_cache,
      impl_->output_name_ptrs,
      [this](std::size_t index) -> Ort::AllocatedStringPtr { return impl_->session->GetOutputNameAllocated(index, impl_->allocator); });

    impl_->initialized = true;

    return {};
}

auto OnnxInferenceEngine::is_initialized() const -> bool { return impl_->initialized; }

auto OnnxInferenceEngine::run_inference(std::span<const float> input_data,
  const TensorShape &input_shape,
  const std::string &input_name) -> std::expected<InferenceResult, OnnxError>
{

    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    const auto expected_size = input_shape.total_elements();
    if (input_data.size() != expected_size) { return std::unexpected(OnnxError::InvalidInputShape); }

    const auto input_dims = to_ort_dimensions(input_shape);
    std::vector<float> mutable_input(input_data.begin(), input_data.end());

    Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
      memory_info, mutable_input.data(), mutable_input.size(), input_dims.data(), input_dims.size());

    const char *input_name_ptr = input_name.c_str();

    const auto start_time = InferenceClock::now();

    const auto output_tensors = impl_->session->Run(Ort::RunOptions{ nullptr },
      &input_name_ptr,
      &input_tensor,
      1,
      impl_->output_name_ptrs.data(),
      impl_->output_name_ptrs.size());

    return make_inference_result(output_tensors, start_time, InferenceClock::now());
}

auto OnnxInferenceEngine::run_inference_multi_input(const std::vector<std::pair<std::string, TensorData>> &inputs)
  -> std::expected<InferenceResult, OnnxError>
{

    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    // Ort::Value borrows input buffers, so the copied inputs must stay alive
    // until Session::Run() has completed.
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

        auto input_tensor = Ort::Value::CreateTensor<float>(
          memory_info, mutable_data.data(), mutable_data.size(), dims.data(), dims.size());

        input_tensors.push_back(std::move(input_tensor));
        input_names.push_back(name.c_str());
    }

    const auto start_time = InferenceClock::now();

    const auto output_tensors = impl_->session->Run(Ort::RunOptions{ nullptr },
      input_names.data(),
      input_tensors.data(),
      input_tensors.size(),
      impl_->output_name_ptrs.data(),
      impl_->output_name_ptrs.size());

    return make_inference_result(output_tensors, start_time, InferenceClock::now());
}

auto OnnxInferenceEngine::get_input_names() const -> std::vector<std::string> { return impl_->input_names_cache; }

auto OnnxInferenceEngine::get_output_names() const -> std::vector<std::string> { return impl_->output_names_cache; }

auto OnnxInferenceEngine::get_input_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>
{
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    return get_named_shape(
      impl_->input_names_cache, name, [this](std::size_t index) -> Ort::TypeInfo { return impl_->session->GetInputTypeInfo(index); });
}

auto OnnxInferenceEngine::get_output_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>
{
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    return get_named_shape(
      impl_->output_names_cache, name, [this](std::size_t index) -> Ort::TypeInfo { return impl_->session->GetOutputTypeInfo(index); });
}

auto create_default_session_config(const std::filesystem::path &model_path) -> SessionConfig
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
