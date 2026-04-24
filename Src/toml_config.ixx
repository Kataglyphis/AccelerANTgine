module;

#include "kataglyphis_export.h"
#include <cstdint>
#include <expected>
#include <filesystem>
#include <string>
#include <vector>

export module kataglyphis.toml_config;

export namespace kataglyphis::config {

enum class TomlConfigError {
    FileNotFound,
    ParseError,
    MissingField,
    InvalidValue
};

struct ModelConfig {
    std::string model_path{};
    std::string framework{"onnx"};
    std::uint32_t input_width{640};
    std::uint32_t input_height{640};
    double confidence_threshold{0.25};
    double iou_threshold{0.45};
    std::vector<std::string> labels{};
};

struct PipelineConfig {
    std::string camera_device{"0"};
    std::uint32_t capture_width{1280};
    std::uint32_t capture_height{720};
    std::uint32_t capture_fps{30};
    bool enable_inference{true};
    bool enable_overlay{true};
};

struct InferenceConfig {
    ModelConfig model;
    PipelineConfig pipeline;
    std::string log_level{"info"};
};

[[nodiscard]] KATAGLYPHIS_CPP_API auto load_inference_config(
    const std::filesystem::path& config_path
) -> std::expected<InferenceConfig, TomlConfigError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto parse_inference_config(
    const std::string& toml_content
) -> std::expected<InferenceConfig, TomlConfigError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto get_default_inference_config() -> InferenceConfig;

} // namespace kataglyphis::config