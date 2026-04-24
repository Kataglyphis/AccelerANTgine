module;

#include <expected>
#include <filesystem>
#include <string>

module kataglyphis.toml_config;

import tomlplusplus;

namespace kataglyphis::config {

auto get_default_inference_config() -> InferenceConfig
{
    InferenceConfig config;
    config.model.labels = {"person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light"};
    config.pipeline.enable_inference = true;
    config.pipeline.enable_overlay = true;
    return config;
}

static auto populate_config(toml::parse_result& result, InferenceConfig& config) -> void
{
    if (auto *model = result["model"].as_table()) {
        if (auto *val = model->get("model_path")) {
            if (val->is_string()) { config.model.model_path = val->value_or(std::string{}); }
        }
        if (auto *val = model->get("framework")) {
            if (val->is_string()) { config.model.framework = val->value_or(std::string{"onnx"}); }
        }
        if (auto *val = model->get("input_width")) {
            config.model.input_width = val->value_or<std::uint32_t>(640);
        }
        if (auto *val = model->get("input_height")) {
            config.model.input_height = val->value_or<std::uint32_t>(640);
        }
        if (auto *val = model->get("confidence_threshold")) {
            config.model.confidence_threshold = val->value_or(0.25);
        }
        if (auto *val = model->get("iou_threshold")) {
            config.model.iou_threshold = val->value_or(0.45);
        }
        if (auto *labels = model->get("labels")) {
            if (labels->is_array()) {
                for (const auto& label : *labels->as_array()) {
                    if (label.is_string()) {
                        config.model.labels.emplace_back(label.value_or(std::string{}));
                    }
                }
            }
        }
    }

    if (auto *pipeline = result["pipeline"].as_table()) {
        if (auto *val = pipeline->get("camera_device")) {
            if (val->is_string()) { config.pipeline.camera_device = val->value_or(std::string{"0"}); }
        }
        if (auto *val = pipeline->get("capture_width")) {
            config.pipeline.capture_width = val->value_or<std::uint32_t>(1280);
        }
        if (auto *val = pipeline->get("capture_height")) {
            config.pipeline.capture_height = val->value_or<std::uint32_t>(720);
        }
        if (auto *val = pipeline->get("capture_fps")) {
            config.pipeline.capture_fps = val->value_or<std::uint32_t>(30);
        }
        if (auto *val = pipeline->get("enable_inference")) {
            config.pipeline.enable_inference = val->value_or(true);
        }
        if (auto *val = pipeline->get("enable_overlay")) {
            config.pipeline.enable_overlay = val->value_or(true);
        }
    }

    if (auto *general = result["general"].as_table()) {
        if (auto *val = general->get("log_level")) {
            if (val->is_string()) { config.log_level = val->value_or(std::string{"info"}); }
        }
    }
}

auto parse_inference_config(const std::string& toml_content) -> std::expected<InferenceConfig, TomlConfigError>
{
    auto result = toml::parse(toml_content);
    if (!result) {
        return std::unexpected(TomlConfigError::ParseError);
    }

    InferenceConfig config;
    populate_config(result, config);
    return config;
}

auto load_inference_config(const std::filesystem::path& config_path) -> std::expected<InferenceConfig, TomlConfigError>
{
    if (!std::filesystem::exists(config_path)) {
        return std::unexpected(TomlConfigError::FileNotFound);
    }

    auto result = toml::parse_file(config_path.string());
    if (!result) {
        return std::unexpected(TomlConfigError::ParseError);
    }

    InferenceConfig config;
    populate_config(result, config);
    return config;
}

} // namespace kataglyphis::config