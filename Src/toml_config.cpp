module;

#include <cstdint>
#include <expected>
#include <filesystem>
#include <initializer_list>
#include <limits>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

module kataglyphis.toml_config;

import tomlplusplus;
import kataglyphis.log;

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

    // The key and what it should have held, logged once: the caller only sees InvalidValue, as from the JSON loader.
    auto refuse(std::string_view key, std::string_view wanted) -> std::expected<void, ConfigError>
    {
        log::error("config: {} must be {}", key, wanted);
        return std::unexpected(ConfigError::InvalidValue);
    }

    // A key the table holds must have the field's type and fit it; a key it lacks keeps the default.
    template<typename T>
    auto take(const toml::table &table, std::string_view key, T &field) -> std::expected<void, ConfigError>
    {
        const auto *val = table.get(key);
        if (val == nullptr) { return {}; }
        if constexpr (std::is_same_v<T, bool>) {
            if (!val->is_boolean()) { return refuse(key, "true or false"); }
            field = val->value_or(false);
        } else if constexpr (std::is_floating_point_v<T>) {
            // An integer is a number too: confidence_threshold = 1 means 1.0.
            if (!val->is_number()) { return refuse(key, "a number"); }
            field = val->value_or(T{});
        } else {
            const auto *whole = val->as_integer();
            if (whole == nullptr) { return refuse(key, "a whole number"); }
            const std::int64_t number = whole->get();
            if (number < 0 || std::cmp_greater(number, std::numeric_limits<T>::max())) {
                return refuse(key, "a whole number from 0 to " + std::to_string(std::numeric_limits<T>::max()));
            }
            field = static_cast<T>(number);
        }
        return {};
    }

    auto take_string(const toml::table &table, std::string_view key, std::string &field)
      -> std::expected<void, ConfigError>
    {
        const auto *val = table.get(key);
        if (val == nullptr) { return {}; }
        if (!val->is_string()) { return refuse(key, "text"); }
        field = val->value_or(std::string{});
        return {};
    }

    auto take_labels(const toml::table &model, std::vector<std::string> &labels) -> std::expected<void, ConfigError>
    {
        const auto *val = model.get("labels");
        if (val == nullptr) { return {}; }
        const auto *array = val->as_array();
        if (array == nullptr) { return refuse("labels", "a list of texts"); }
        labels.clear();
        for (const auto &label : *array) {
            if (!label.is_string()) { return refuse("labels", "a list of texts"); }
            labels.emplace_back(label.value_or(std::string{}));
        }
        return {};
    }

    // The first refusal in field order; every key is still checked, so one run names the first problem.
    auto first_error(std::initializer_list<std::expected<void, ConfigError>> results)
      -> std::expected<void, ConfigError>
    {
        for (const auto &result : results) {
            if (!result) { return std::unexpected(result.error()); }
        }
        return {};
    }

    auto populate_model(const toml::table &model, ModelConfig &config) -> std::expected<void, ConfigError>
    {
        return first_error({
          take_string(model, "model_path", config.model_path),
          take_string(model, "framework", config.framework),
          take<std::uint32_t>(model, "input_width", config.input_width),
          take<std::uint32_t>(model, "input_height", config.input_height),
          take(model, "confidence_threshold", config.confidence_threshold),
          take(model, "iou_threshold", config.iou_threshold),
          take<std::uint32_t>(model, "intra_op_threads", config.intra_op_threads),
          take_string(model, "output_layout", config.output_layout),
          take_labels(model, config.labels),
        });
    }

    auto populate_pipeline(const toml::table &pipeline, PipelineConfig &config) -> std::expected<void, ConfigError>
    {
        return first_error({
          take_string(pipeline, "camera_device", config.camera_device),
          take<std::uint32_t>(pipeline, "capture_width", config.capture_width),
          take<std::uint32_t>(pipeline, "capture_height", config.capture_height),
          take<std::uint32_t>(pipeline, "capture_fps", config.capture_fps),
          take(pipeline, "enable_inference", config.enable_inference),
          take(pipeline, "enable_overlay", config.enable_overlay),
        });
    }

    auto populate_config(toml::parse_result &result, InferenceConfig &config) -> std::expected<void, ConfigError>
    {
        std::expected<void, ConfigError> model;
        std::expected<void, ConfigError> pipeline;
        std::expected<void, ConfigError> general;
        if (const auto *table = result["model"].as_table()) { model = populate_model(*table, config.model); }
        if (const auto *table = result["pipeline"].as_table()) {
            pipeline = populate_pipeline(*table, config.pipeline);
        }
        if (const auto *table = result["general"].as_table()) {
            general = take_string(*table, "log_level", config.log_level);
        }
        return first_error({ model, pipeline, general });
    }

}// namespace

auto parse_inference_config(const std::string &toml_content) -> std::expected<InferenceConfig, ConfigError>
{
    auto result = toml::parse(toml_content);
    if (!result) { return std::unexpected(ConfigError::ParseError); }

    InferenceConfig config;
    if (auto populated = populate_config(result, config); !populated) { return std::unexpected(populated.error()); }
    return config;
}

auto load_inference_config(const std::filesystem::path &config_path) -> std::expected<InferenceConfig, ConfigError>
{
    if (!std::filesystem::exists(config_path)) { return std::unexpected(ConfigError::FileNotFound); }

    auto result = toml::parse_file(config_path.string());
    if (!result) { return std::unexpected(ConfigError::ParseError); }

    InferenceConfig config;
    if (auto populated = populate_config(result, config); !populated) { return std::unexpected(populated.error()); }
    return config;
}

}// namespace kataglyphis::config