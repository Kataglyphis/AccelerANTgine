// The ORT-backed detector: a model's checks against its config, then preprocess, run and decode per frame.
module;

#include "kataglyphis_export.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <expected>
#include <filesystem>
#include <functional>
#include <limits>
#include <mutex>
#include <numeric>
#include <optional>
#include <ranges>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <utility>

module kataglyphis.yolo_detector;

import kataglyphis.onnx_inference;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.toml_config;
import kataglyphis.project_config;
import kataglyphis.log;

namespace kataglyphis::detection {

namespace {
    // A dimension the model fixes; dynamic ones come back as 0 or as a wrapped -1.
    auto fixed(const std::vector<std::optional<std::size_t>> &dimensions, std::size_t index)
      -> std::optional<std::size_t>
    {
        if (index >= dimensions.size() || !dimensions[index]) { return std::nullopt; }
        const std::size_t value = *dimensions[index];
        if (value == 0 || value > static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
            return std::nullopt;
        }
        return value;
    }

    // The input tensor, its size and the output layout, as far as the model file fixes them, against the config.
    auto model_fits(const inference::OnnxInferenceEngine &engine, const YoloConfig &config, std::string_view declared)
      -> std::expected<void, OnnxError>
    {
        const auto input = engine.get_input_shape("images");
        if (!input) {
            log::error("The detector model has no input named images");
            return std::unexpected(OnnxError::InvalidInputShape);
        }
        const auto height = fixed(input->dimensions, 2);
        const auto width = fixed(input->dimensions, 3);
        if ((height && *height != config.input_height) || (width && *width != config.input_width)) {
            log::error("The detector model takes {}x{} frames, the config says {}x{}",
              width.value_or(0),
              height.value_or(0),
              config.input_width,
              config.input_height);
            return std::unexpected(OnnxError::InvalidInputShape);
        }
        if (const auto layout = layout_from_metadata(declared); layout && *layout != config.output_layout) {
            log::error(
              "The detector model names its output layout {}, the config another: set output_layout to auto", declared);
            return std::unexpected(OnnxError::InvalidOutputShape);
        }
        std::optional<std::size_t> values;
        if (const auto outputs = engine.get_output_names(); !outputs.empty()) {
            if (const auto output = engine.get_output_shape(outputs.front()); output && !output->dimensions.empty()) {
                values = fixed(output->dimensions, output->dimensions.size() - 1);
            }
        }
        if (config.output_layout == YoloOutputLayout::CornersScoreClass && values && *values != 6) {
            log::error("Corner rows have 6 values, the detector model's output has {}", *values);
            return std::unexpected(OnnxError::InvalidOutputShape);
        }
        return {};
    }

    // The model's own word on how a frame is fitted: the other fitting gives wrong boxes on every frame, without an error.
    auto preprocess_fits(const inference::OnnxInferenceEngine &engine, const YoloConfig &config)
      -> std::expected<void, OnnxError>
    {
        const auto named = engine.get_custom_metadata("kataglyphis.preprocess");
        const std::string_view wanted =
          config.preprocess_mode == FramePreprocessMode::Letterbox ? "letterbox" : "stretch";
        if (!named || named->empty() || *named == wanted) { return {}; }
        log::error("The detector model names its preprocessing {}, the config says {}", *named, wanted);
        return std::unexpected(OnnxError::InvalidInputShape);
    }
}// namespace

auto yolo_config_from(const config::ModelConfig &model) -> std::expected<YoloConfig, config::ConfigError>
{
    YoloConfig config;
    if (model.output_layout == "auto") {
        config.output_layout = YoloOutputLayout::Auto;
    } else if (!model.output_layout.empty()) {
        const auto layout = layout_from_metadata(model.output_layout);
        if (!layout) { return std::unexpected(config::ConfigError::InvalidValue); }
        config.output_layout = *layout;
    }
    config.model_path = model.model_path;
    config.input_width = model.input_width;
    config.input_height = model.input_height;
    config.confidence_threshold = static_cast<float>(model.confidence_threshold);
    config.nms_threshold = static_cast<float>(model.iou_threshold);
    config.labels = model.labels;
    if (!model.labels.empty()) { config.num_classes = static_cast<int>(model.labels.size()); }
    if (model.intra_op_threads > 0) { config.intra_op_num_threads = static_cast<int>(model.intra_op_threads); }
    return config;
}

struct YoloDetector::Impl
{
    // detect reads config while initialize rewrites it; the engine guards only its own session.
    mutable std::shared_mutex mutex;
    inference::OnnxInferenceEngine engine;
    YoloConfig config;
    bool initialized{ false };
};

YoloDetector::YoloDetector() : impl_(std::make_unique<Impl>()) {}

YoloDetector::~YoloDetector() = default;

YoloDetector::YoloDetector(YoloDetector &&) noexcept = default;

auto YoloDetector::operator=(YoloDetector &&) noexcept -> YoloDetector & = default;

auto YoloDetector::initialize(const YoloConfig &config) -> std::expected<void, OnnxError>
{ return initialize(config, {}); }

auto YoloDetector::initialize(const YoloConfig &config, const std::filesystem::path &profiling_prefix)
  -> std::expected<void, OnnxError>
{
    const std::unique_lock lock(impl_->mutex);
    impl_->initialized = false;
    if (config.input_width == 0 || config.input_height == 0) { return std::unexpected(OnnxError::InvalidInputShape); }
    impl_->config = config;

    auto session_config = inference::create_default_session_config(config.model_path);
    session_config.execution_provider = config.execution_provider;
    session_config.device_id = config.device_id;
    session_config.intra_op_num_threads = config.intra_op_num_threads;
    session_config.inter_op_num_threads = config.inter_op_num_threads;
    session_config.profiling_prefix = profiling_prefix;

    auto result = impl_->engine.initialize(session_config);
    if (!result) { return std::unexpected(result.error()); }

    const auto named = impl_->engine.get_custom_metadata("kataglyphis.output");
    const auto declared = named ? layout_from_metadata(*named) : std::nullopt;
    if (config.output_layout == YoloOutputLayout::Auto) {
        if (!declared) { return std::unexpected(OnnxError::InvalidOutputShape); }
        impl_->config.output_layout = *declared;
    }
    // At the start, with the reason: a model that does not fit the config otherwise fails every frame, or decodes nonsense.
    if (auto fits = model_fits(impl_->engine, impl_->config, named ? std::string_view(*named) : std::string_view{});
      !fits) {
        return std::unexpected(fits.error());
    }
    if (auto fits = preprocess_fits(impl_->engine, impl_->config); !fits) { return std::unexpected(fits.error()); }

    impl_->initialized = true;
    return {};
}

auto YoloDetector::output_layout() const -> YoloOutputLayout
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->config.output_layout;
}

auto YoloDetector::applied_intra_op_num_threads() const -> int
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->engine.applied_intra_op_num_threads();
}

auto YoloDetector::last_error() const -> std::string { return impl_->engine.last_error(); }

auto YoloDetector::is_initialized() const -> bool
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->initialized;
}

auto YoloDetector::end_profiling() -> std::expected<std::string, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }
    return impl_->engine.end_profiling();
}

auto YoloDetector::detect(std::span<const float> image_data, std::uint32_t width, std::uint32_t height)
  -> std::expected<DetectionResult, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }
    if (width == 0 || height == 0) { return std::unexpected(OnnxError::InvalidInputShape); }

    inference::TensorShape input_shape;
    input_shape.dimensions = { 1, 3, impl_->config.input_height, impl_->config.input_width };

    auto result = impl_->engine.run_inference(image_data, input_shape, "images");

    if (!result) { return std::unexpected(result.error()); }

    const FrameMapping mapping{ static_cast<float>(impl_->config.input_width) / width,
        static_cast<float>(impl_->config.input_height) / height,
        0.0F,
        0.0F,
        width,
        height };
    return post_process(result.value(), mapping);
}

auto YoloDetector::detect_from_gstreamer(gstreamer::GStreamerPipeline &pipeline, std::uint32_t timeout_ms)
  -> std::expected<DetectionResult, OnnxError>
{
    if (!is_initialized()) { return std::unexpected(OnnxError::SessionNotInitialized); }

    auto buffer_result = pipeline.pull_sample(timeout_ms);
    if (!buffer_result) {
        // A late frame is worth another pull, the end is not; a broken stream and a missing sink each say which.
        if (buffer_result.error() == gstreamer::GStreamerError::StreamError) {
            return std::unexpected(OnnxError::StreamBroken);
        }
        if (buffer_result.error() != gstreamer::GStreamerError::BufferAllocationFailed) {
            return std::unexpected(OnnxError::InputAllocationFailed);
        }
        return std::unexpected(pipeline.has_ended() ? OnnxError::EndOfStream : OnnxError::FrameTimeout);
    }

    return detect_frame(*buffer_result);
}

auto YoloDetector::detect_frame(const gstreamer::BufferInfo &frame) -> std::expected<DetectionResult, OnnxError>
{
    PreprocessedFrame input;
    return detect_frame(frame, input);
}

auto YoloDetector::detect_frame(const gstreamer::BufferInfo &frame, PreprocessedFrame &scratch)
  -> std::expected<DetectionResult, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }
    if (auto done = preprocess_frame_into(
          frame, impl_->config.input_width, impl_->config.input_height, impl_->config.preprocess_mode, scratch);
      !done) {
        return std::unexpected(done.error());
    }
    inference::TensorShape shape{ { 1, 3, impl_->config.input_height, impl_->config.input_width } };
    auto result = impl_->engine.run_inference_in_place(scratch.data, shape, "images");
    if (!result) { return std::unexpected(result.error()); }
    return post_process(*result, scratch.mapping);
}

auto YoloDetector::post_process(const inference::InferenceResult &raw_output, const FrameMapping &mapping)
  -> std::expected<DetectionResult, OnnxError>
{
    DetectionResult result;
    result.original_width = mapping.frame_width;
    result.original_height = mapping.frame_height;
    result.inference_time_ms = raw_output.inference_time_ms;
    if (raw_output.outputs.empty()) { return result; }
    auto boxes = decode_detections(raw_output.outputs[0], impl_->config, mapping);
    if (!boxes) { return std::unexpected(boxes.error()); }
    result.boxes = std::move(*boxes);
    return result;
}

}// namespace kataglyphis::detection
