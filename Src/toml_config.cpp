module;

#include <expected>
#include <filesystem>
#include <string>
#include <string_view>
#include <utility>

module kataglyphis.toml_config;

import tomlplusplus;

namespace kataglyphis::config {

auto get_default_inference_config() -> InferenceConfig
{
    InferenceConfig config;
    config.model.labels = {
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light"
    };
    config.pipeline.enable_inference = true;
    config.pipeline.enable_overlay = true;
    return config;
}

namespace {

    // A key the table holds replaces the field; a value of another type gives `fallback`, as value_or does.
    template<typename T> auto take(const toml::table &table, std::string_view key, T &field, T fallback) -> void
    {
        if (const auto *val = table.get(key)) { field = val->value_or<T>(std::move(fallback)); }
    }

    // A text key replaces the field only when it holds text.
    auto take_string(const toml::table &table, std::string_view key, std::string &field) -> void
    {
        if (const auto *val = table.get(key); val != nullptr && val->is_string()) {
            field = val->value_or(std::string{});
        }
    }

    auto populate_model(const toml::table &model, ModelConfig &config) -> void
    {
        take_string(model, "model_path", config.model_path);
        take_string(model, "framework", config.framework);
        take<std::uint32_t>(model, "input_width", config.input_width, 640);
        take<std::uint32_t>(model, "input_height", config.input_height, 640);
        take(model, "confidence_threshold", config.confidence_threshold, 0.25);
        take(model, "iou_threshold", config.iou_threshold, 0.45);
        take<std::uint32_t>(model, "intra_op_threads", config.intra_op_threads, 0);
        take_string(model, "output_layout", config.output_layout);
        if (const auto *labels = model.get_as<toml::array>("labels")) {
            for (const auto &label : *labels) {
                if (label.is_string()) { config.labels.emplace_back(label.value_or(std::string{})); }
            }
        }
    }

    auto populate_pipeline(const toml::table &pipeline, PipelineConfig &config) -> void
    {
        take_string(pipeline, "camera_device", config.camera_device);
        take<std::uint32_t>(pipeline, "capture_width", config.capture_width, 1280);
        take<std::uint32_t>(pipeline, "capture_height", config.capture_height, 720);
        take<std::uint32_t>(pipeline, "capture_fps", config.capture_fps, 30);
        take(pipeline, "enable_inference", config.enable_inference, true);
        take(pipeline, "enable_overlay", config.enable_overlay, true);
    }

    auto populate_config(toml::parse_result &result, InferenceConfig &config) -> void
    {
        if (const auto *model = result["model"].as_table()) { populate_model(*model, config.model); }
        if (const auto *pipeline = result["pipeline"].as_table()) { populate_pipeline(*pipeline, config.pipeline); }
        if (const auto *general = result["general"].as_table()) {
            take_string(*general, "log_level", config.log_level);
        }
    }

}// namespace

auto parse_inference_config(const std::string &toml_content) -> std::expected<InferenceConfig, ConfigError>
{
    auto result = toml::parse(toml_content);
    if (!result) { return std::unexpected(ConfigError::ParseError); }

    InferenceConfig config;
    populate_config(result, config);
    return config;
}

auto load_inference_config(const std::filesystem::path &config_path) -> std::expected<InferenceConfig, ConfigError>
{
    if (!std::filesystem::exists(config_path)) { return std::unexpected(ConfigError::FileNotFound); }

    auto result = toml::parse_file(config_path.string());
    if (!result) { return std::unexpected(ConfigError::ParseError); }

    InferenceConfig config;
    populate_config(result, config);
    return config;
}

}// namespace kataglyphis::config