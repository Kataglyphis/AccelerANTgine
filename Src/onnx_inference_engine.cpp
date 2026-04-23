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

OnnxInferenceEngine::OnnxInferenceEngine(OnnxInferenceEngine &&other) noexcept : impl_(std::move(other.impl_)) {}

auto OnnxInferenceEngine::operator=(OnnxInferenceEngine &&other) noexcept -> OnnxInferenceEngine &
{
    if (this != &other) { impl_ = std::move(other.impl_); }
    return *this;
}

auto OnnxInferenceEngine::initialize(const SessionConfig &config) -> std::expected<void, OnnxError>
{
    impl_->config = config;

    impl_->env = std::make_unique<Ort::Env>(OrtLoggingLevel::ORT_LOGGING_LEVEL_WARNING, "KataglyphisOnnxRuntime");

    impl_->session_options = std::make_unique<Ort::SessionOptions>();

    impl_->session_options->SetIntraOpNumThreads(config.intra_op_num_threads);
    impl_->session_options->SetInterOpNumThreads(config.inter_op_num_threads);

    if (config.execution_mode == "parallel") {
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

    Ort::AllocatorWithDefaultOptions allocator;

    const size_t num_inputs = impl_->session->GetInputCount();
    impl_->input_names_cache.clear();
    impl_->input_name_ptrs.clear();

    for (size_t i = 0; i < num_inputs; ++i) {
        auto name = impl_->session->GetInputNameAllocated(i, allocator);
        impl_->input_names_cache.emplace_back(name.get());
        impl_->input_name_ptrs.push_back(impl_->input_names_cache.back().c_str());
    }

    const size_t num_outputs = impl_->session->GetOutputCount();
    impl_->output_names_cache.clear();
    impl_->output_name_ptrs.clear();

    for (size_t i = 0; i < num_outputs; ++i) {
        auto name = impl_->session->GetOutputNameAllocated(i, allocator);
        impl_->output_names_cache.emplace_back(name.get());
        impl_->output_name_ptrs.push_back(impl_->output_names_cache.back().c_str());
    }

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

    std::vector<int64_t> input_dims;
    input_dims.reserve(input_shape.dimensions.size());
    for (const auto dim : input_shape.dimensions) { input_dims.push_back(static_cast<int64_t>(dim)); }

    Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
      memory_info, const_cast<float *>(input_data.data()), input_data.size(), input_dims.data(), input_dims.size());

    const char *input_name_ptr = input_name.c_str();

    auto start_time = std::chrono::high_resolution_clock::now();

    auto output_tensors = impl_->session->Run(Ort::RunOptions{ nullptr },
      &input_name_ptr,
      &input_tensor,
      1,
      impl_->output_name_ptrs.data(),
      impl_->output_name_ptrs.size());

    auto end_time = std::chrono::high_resolution_clock::now();

    InferenceResult result;
    result.inference_time_ms = std::chrono::duration<double, std::milli>(end_time - start_time).count();

    for (auto &tensor : output_tensors) {
        TensorData tensor_data;
        const auto &type_info = tensor.GetTensorTypeAndShapeInfo();
        const auto shape = type_info.GetShape();

        for (const auto dim : shape) { tensor_data.shape.dimensions.push_back(static_cast<std::size_t>(dim)); }

        const auto total_elements = type_info.GetElementCount();
        const auto *tensor_data_ptr = tensor.GetTensorData<float>();

        tensor_data.data.assign(tensor_data_ptr, tensor_data_ptr + total_elements);
        result.outputs.push_back(std::move(tensor_data));
    }

    return result;
}

auto OnnxInferenceEngine::run_inference_multi_input(const std::vector<std::pair<std::string, TensorData>> &inputs)
  -> std::expected<InferenceResult, OnnxError>
{

    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    std::vector<Ort::Value> input_tensors;
    std::vector<const char *> input_names;
    input_tensors.reserve(inputs.size());
    input_names.reserve(inputs.size());

    for (const auto &[name, tensor_data] : inputs) {
        std::vector<int64_t> dims;
        dims.reserve(tensor_data.shape.dimensions.size());
        for (const auto dim : tensor_data.shape.dimensions) { dims.push_back(static_cast<int64_t>(dim)); }

        auto input_tensor = Ort::Value::CreateTensor<float>(
          memory_info, const_cast<float *>(tensor_data.data.data()), tensor_data.data.size(), dims.data(), dims.size());

        input_tensors.push_back(std::move(input_tensor));
        input_names.push_back(name.c_str());
    }

    auto start_time = std::chrono::high_resolution_clock::now();

    auto output_tensors = impl_->session->Run(Ort::RunOptions{ nullptr },
      input_names.data(),
      input_tensors.data(),
      input_tensors.size(),
      impl_->output_name_ptrs.data(),
      impl_->output_name_ptrs.size());

    auto end_time = std::chrono::high_resolution_clock::now();

    InferenceResult result;
    result.inference_time_ms = std::chrono::duration<double, std::milli>(end_time - start_time).count();

    for (auto &tensor : output_tensors) {
        TensorData tensor_data;
        const auto &type_info = tensor.GetTensorTypeAndShapeInfo();
        const auto shape = type_info.GetShape();

        for (const auto dim : shape) { tensor_data.shape.dimensions.push_back(static_cast<std::size_t>(dim)); }

        const auto total_elements = type_info.GetElementCount();
        const auto *tensor_data_ptr = tensor.GetTensorData<float>();

        tensor_data.data.assign(tensor_data_ptr, tensor_data_ptr + total_elements);
        result.outputs.push_back(std::move(tensor_data));
    }

    return result;
}

auto OnnxInferenceEngine::get_input_names() const -> std::vector<std::string> { return impl_->input_names_cache; }

auto OnnxInferenceEngine::get_output_names() const -> std::vector<std::string> { return impl_->output_names_cache; }

auto OnnxInferenceEngine::get_input_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>
{
    for (size_t i = 0; i < impl_->input_names_cache.size(); ++i) {
        if (impl_->input_names_cache[i] == name) {
            const auto type_info = impl_->session->GetInputTypeInfo(i);
            const auto &shape_info = type_info.GetTensorTypeAndShapeInfo();
            const auto dims = shape_info.GetShape();

            TensorShape result;
            for (const auto dim : dims) { result.dimensions.push_back(static_cast<std::size_t>(dim)); }
            return result;
        }
    }
    return std::unexpected(OnnxError::InvalidInputShape);
}

auto OnnxInferenceEngine::get_output_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>
{
    for (size_t i = 0; i < impl_->output_names_cache.size(); ++i) {
        if (impl_->output_names_cache[i] == name) {
            const auto type_info = impl_->session->GetOutputTypeInfo(i);
            const auto &shape_info = type_info.GetTensorTypeAndShapeInfo();
            const auto dims = shape_info.GetShape();

            TensorShape result;
            for (const auto dim : dims) { result.dimensions.push_back(static_cast<std::size_t>(dim)); }
            return result;
        }
    }
    return std::unexpected(OnnxError::InvalidInputShape);
}

auto create_default_session_config(const std::filesystem::path &model_path) -> SessionConfig
{
    SessionConfig config;
    config.model_path = model_path;
    config.intra_op_num_threads = 4;
    config.inter_op_num_threads = 4;
    config.enable_cuda = false;
    config.enable_memory_pattern = true;
    config.execution_mode = "sequential";
    return config;
}

}// namespace kataglyphis::inference