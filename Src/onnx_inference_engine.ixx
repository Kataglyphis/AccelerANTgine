module;

#include "kataglyphis_export.h"
#include <cstddef>
#include <expected>
#include <filesystem>
#include <memory>
#include <span>
#include <string>
#include <vector>

export module kataglyphis.onnx_inference;

export namespace kataglyphis::inference {

enum class OnnxError {
    SessionCreationFailed,
    ModelLoadFailed,
    InputAllocationFailed,
    OutputAllocationFailed,
    InferenceFailed,
    InvalidInputShape,
    InvalidInputType,
    MemoryAllocationError,
    SessionNotInitialized
};

struct TensorShape
{
    std::vector<std::size_t> dimensions;

    [[nodiscard]] auto total_elements() const -> std::size_t
    {
        std::size_t total = 1;
        for (auto dim : dimensions) { total *= dim; }
        return total;
    }
};

struct TensorData
{
    std::vector<float> data;
    TensorShape shape;
};

struct InferenceResult
{
    std::vector<TensorData> outputs;
    double inference_time_ms{};
};

struct SessionConfig
{
    std::filesystem::path model_path;
    int intra_op_num_threads = 4;
    int inter_op_num_threads = 4;
    bool enable_cuda = false;
    bool enable_memory_pattern = true;
    std::string execution_mode = "sequential";
};

class KATAGLYPHIS_CPP_API OnnxInferenceEngine
{
  public:
    OnnxInferenceEngine();
    ~OnnxInferenceEngine();

    OnnxInferenceEngine(const OnnxInferenceEngine &) = delete;
    auto operator=(const OnnxInferenceEngine &) -> OnnxInferenceEngine & = delete;
    OnnxInferenceEngine(OnnxInferenceEngine && /*other*/) noexcept;
    auto operator=(OnnxInferenceEngine && /*other*/) noexcept -> OnnxInferenceEngine &;

    [[nodiscard]] auto initialize(const SessionConfig &config) -> std::expected<void, OnnxError>;

    [[nodiscard]] auto is_initialized() const -> bool;

    [[nodiscard]] auto run_inference(std::span<const float> input_data,
      const TensorShape &input_shape,
      const std::string &input_name = "input") -> std::expected<InferenceResult, OnnxError>;

    [[nodiscard]] auto run_inference_multi_input(const std::vector<std::pair<std::string, TensorData>> &inputs)
      -> std::expected<InferenceResult, OnnxError>;

    [[nodiscard]] auto get_input_names() const -> std::vector<std::string>;
    [[nodiscard]] auto get_output_names() const -> std::vector<std::string>;
    [[nodiscard]] auto get_input_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>;
    [[nodiscard]] auto get_output_shape(const std::string &name) const -> std::expected<TensorShape, OnnxError>;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] auto create_default_session_config(const std::filesystem::path &model_path) -> SessionConfig;

}// namespace kataglyphis::inference