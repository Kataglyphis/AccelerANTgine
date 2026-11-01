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
#include <shared_mutex>
#include <span>
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
    constexpr std::array<const char *, 80> COCO_CLASSES = { "person",
        "bicycle",
        "car",
        "motorcycle",
        "airplane",
        "bus",
        "train",
        "truck",
        "boat",
        "traffic light",
        "fire hydrant",
        "stop sign",
        "parking meter",
        "bench",
        "bird",
        "cat",
        "dog",
        "horse",
        "sheep",
        "cow",
        "elephant",
        "bear",
        "zebra",
        "giraffe",
        "backpack",
        "umbrella",
        "handbag",
        "tie",
        "suitcase",
        "frisbee",
        "skis",
        "snowboard",
        "sports ball",
        "kite",
        "baseball bat",
        "baseball glove",
        "skateboard",
        "surfboard",
        "tennis racket",
        "bottle",
        "wine glass",
        "cup",
        "fork",
        "knife",
        "spoon",
        "bowl",
        "banana",
        "apple",
        "sandwich",
        "orange",
        "broccoli",
        "carrot",
        "hot dog",
        "pizza",
        "donut",
        "cake",
        "chair",
        "couch",
        "potted plant",
        "bed",
        "dining table",
        "toilet",
        "tv",
        "laptop",
        "mouse",
        "remote",
        "keyboard",
        "cell phone",
        "microwave",
        "oven",
        "toaster",
        "sink",
        "refrigerator",
        "book",
        "clock",
        "vase",
        "scissors",
        "teddy bear",
        "hair drier",
        "toothbrush" };

    auto build_camera_detection_pipeline_description(const std::string &device,
      std::uint32_t width,
      std::uint32_t height,
      std::uint32_t fps) -> std::string
    {
        return "v4l2src device=" + device + " ! "
               "video/x-raw,width="
               + std::to_string(width) + ",height=" + std::to_string(height) + ",framerate="
               + std::to_string(fps)
               + "/1 ! "
                 "videoconvert ! video/x-raw,format=RGB ! "
                 "appsink name=detector_sink emit-signals=true sync=false";
    }

    auto build_video_detection_pipeline_description(const std::string &video_source,
      std::uint32_t width,
      std::uint32_t height) -> std::string
    {
        std::string pipeline_desc;

        if (video_source.contains("://")) {
            pipeline_desc = "uridecodebin uri=" + video_source + " ! ";
        } else {
            pipeline_desc = "filesrc location=" + video_source + " ! decodebin ! ";
        }

        pipeline_desc +=
          "videoconvert ! videoscale ! "
          "video/x-raw,format=RGB,width="
          + std::to_string(width) + ",height=" + std::to_string(height)
          + " ! appsink name=detector_sink emit-signals=true sync=false";
        return pipeline_desc;
    }

    // Frame pixels per model-input pixel, by which every decoded box is scaled.
    struct Scale
    {
        float x;
        float y;
        float offset_x;
        float offset_y;
    };

    auto class_label(int class_id, const YoloConfig &config) -> std::string
    {
        if (config.labels.empty()) { return std::string(YoloDetector::get_coco_class_name(class_id)); }
        if (class_id >= 0 && std::cmp_less(class_id, config.labels.size())) { return config.labels[class_id]; }
        return "unknown";
    }

    auto labelled_box(float x,
      float y,
      float width,
      float height,
      float confidence,
      int class_id,
      const YoloConfig &config) -> BoundingBox
    {
        BoundingBox box;
        box.x = x;
        box.y = y;
        box.width = width;
        box.height = height;
        box.confidence = confidence;
        box.class_id = class_id;
        box.class_name = class_label(class_id, config);
        return box;
    }

    // The best class among scores read through score(c); count may be zero.
    template<typename Score> auto best_class(std::size_t count, Score &&score) -> std::pair<int, float>
    {
        int best = 0;
        float best_score = 0.0F;
        for (std::size_t c = 0; c < count; ++c) {
            if (score(c) > best_score) {
                best_score = score(c);
                best = static_cast<int>(c);
            }
        }
        return { best, best_score };
    }

    auto center_box(std::span<const float, 4> center,
      float confidence,
      int class_id,
      const YoloConfig &config,
      Scale scale) -> std::optional<BoundingBox>
    {
        // NaN fails every comparison, so the thresholds test for acceptance, not rejection.
        if (!(confidence >= config.confidence_threshold) || !std::isfinite(confidence)) { return std::nullopt; }
        if (!std::ranges::all_of(center, [](float v) -> bool { return std::isfinite(v); })) { return std::nullopt; }
        const auto [cx, cy, w, h] = std::array{ center[0], center[1], center[2], center[3] };
        return labelled_box((cx - (w / 2.0F)) * scale.x - scale.offset_x,
          (cy - (h / 2.0F)) * scale.y - scale.offset_y,
          w * scale.x,
          h * scale.y,
          confidence,
          class_id,
          config);
    }

    auto decode_center_rows(std::span<const float> data,
      std::size_t rows,
      std::size_t values,
      const YoloConfig &config,
      Scale scale) -> std::vector<BoundingBox>
    {
        std::vector<BoundingBox> boxes;
        // Class scores beyond the row would be read from the next detection.
        const std::size_t class_count = std::min(static_cast<std::size_t>(std::max(config.num_classes, 0)), values - 5);

        for (std::size_t i = 0; i < rows; ++i) {
            const auto row = data.subspan(i * values, values);
            const float obj_conf = row[4];
            if (!(obj_conf >= config.confidence_threshold)) { continue; }
            auto [class_id, class_conf] = best_class(class_count, [&](std::size_t c) -> float { return row[5 + c]; });
            const float confidence = class_count > 0 ? obj_conf * class_conf : obj_conf;
            if (auto box = center_box(row.first<4>(), confidence, class_id, config, scale)) {
                boxes.push_back(std::move(*box));
            }
        }
        return boxes;
    }

    // Column i of a [4 + classes, anchors] tensor is one candidate: its centre, then a score per class.
    auto decode_anchor_columns(std::span<const float> data, std::size_t anchors, const YoloConfig &config, Scale scale)
      -> std::vector<BoundingBox>
    {
        std::vector<BoundingBox> boxes;
        const auto classes = static_cast<std::size_t>(config.num_classes);
        for (std::size_t i = 0; i < anchors; ++i) {
            const auto at = [&](std::size_t channel) -> float { return data[channel * anchors + i]; };
            const std::array<float, 4> center{ at(0), at(1), at(2), at(3) };
            const auto [class_id, confidence] = best_class(classes, [&](std::size_t c) -> float { return at(4 + c); });
            if (auto box = center_box(center, confidence, class_id, config, scale)) {
                boxes.push_back(std::move(*box));
            }
        }
        return boxes;
    }

    // An end-to-end row worth a box: a finite score over the threshold, a known class, ordered finite corners.
    auto corner_row_is_usable(std::span<const float> row, const YoloConfig &config) -> bool
    {
        if (!(row[4] >= config.confidence_threshold) || !std::isfinite(row[4])) { return false; }
        if (!(row[5] >= 0.0F) || !(row[5] < static_cast<float>(config.num_classes))) { return false; }
        const bool finite = std::ranges::all_of(row.first(4), [](float v) -> bool { return std::isfinite(v); });
        return finite && row[2] >= row[0] && row[3] >= row[1];
    }

    auto decode_corner_rows(std::span<const float> data,
      std::size_t rows,
      std::size_t values,
      const YoloConfig &config,
      Scale scale) -> std::vector<BoundingBox>
    {
        std::vector<BoundingBox> boxes;
        for (std::size_t i = 0; i < rows; ++i) {
            const auto row = data.subspan(i * values, values);
            if (!corner_row_is_usable(row, config)) { continue; }
            boxes.push_back(labelled_box(row[0] * scale.x - scale.offset_x,
              row[1] * scale.y - scale.offset_y,
              (row[2] - row[0]) * scale.x,
              (row[3] - row[1]) * scale.y,
              row[4],
              static_cast<int>(row[5]),
              config));
        }
        return boxes;
    }

    // Rows and values per row of a [1, rows, values] or [rows, values] tensor whose data fills it exactly.
    auto output_matrix(const inference::TensorData &output) -> std::optional<std::pair<std::size_t, std::size_t>>
    {
        const auto &dims = output.shape.dimensions;
        const bool batched = dims.size() == 3 && dims[0] == 1;
        if (!batched && dims.size() != 2) { return std::nullopt; }
        const std::size_t rows = dims[dims.size() - 2];
        const std::size_t values = dims[dims.size() - 1];
        if (values != 0 && rows > std::numeric_limits<std::size_t>::max() / values) { return std::nullopt; }
        if (rows * values != output.data.size()) { return std::nullopt; }
        return std::pair{ rows, values };
    }

    auto calculate_iou(const BoundingBox &a, const BoundingBox &b) -> float
    {
        const float x1 = std::max(a.x, b.x);
        const float y1 = std::max(a.y, b.y);
        const float x2 = std::min(a.x + a.width, b.x + b.width);
        const float y2 = std::min(a.y + a.height, b.y + b.height);
        if (x2 <= x1 || y2 <= y1) { return 0.0F; }
        const float intersection = (x2 - x1) * (y2 - y1);
        return intersection / ((a.width * a.height) + (b.width * b.height) - intersection);
    }

    auto apply_nms(std::vector<BoundingBox> &boxes, float nms_threshold) -> void
    {
        std::ranges::sort(
          boxes, [](const BoundingBox &a, const BoundingBox &b) -> bool { return a.confidence > b.confidence; });
        std::vector<bool> suppressed(boxes.size(), false);
        for (std::size_t i = 0; i < boxes.size(); ++i) {
            if (suppressed[i]) { continue; }
            for (std::size_t j = i + 1; j < boxes.size(); ++j) {
                if (!suppressed[j] && boxes[i].class_id == boxes[j].class_id
                    && calculate_iou(boxes[i], boxes[j]) > nms_threshold) {
                    suppressed[j] = true;
                }
            }
        }
        std::vector<BoundingBox> kept;
        for (std::size_t i = 0; i < boxes.size(); ++i) {
            if (!suppressed[i]) { kept.push_back(std::move(boxes[i])); }
        }
        boxes = std::move(kept);
    }
}// namespace

auto layout_from_metadata(std::string_view value) -> std::optional<YoloOutputLayout>
{
    if (value == "xyxy_score_class") { return YoloOutputLayout::CornersScoreClass; }
    if (value == "cxcywh_objectness_scores") { return YoloOutputLayout::CenterObjectnessScores; }
    if (value == "cxcywh_scores_by_anchor") { return YoloOutputLayout::CenterScoresByAnchor; }
    return std::nullopt;
}

auto yolo_config_from(const config::ModelConfig &model) -> YoloConfig
{
    YoloConfig config;
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

auto decode_detections(const inference::TensorData &output, const YoloConfig &config, const FrameMapping &mapping)
  -> std::expected<std::vector<BoundingBox>, OnnxError>
{
    const auto matrix = output_matrix(output);
    if (!matrix) { return std::unexpected(OnnxError::InvalidOutputShape); }
    const auto [rows, values] = *matrix;
    const std::span<const float> data(output.data);
    const Scale scale{
        1.0F / mapping.scale_x, 1.0F / mapping.scale_y, mapping.pad_x / mapping.scale_x, mapping.pad_y / mapping.scale_y
    };
    std::vector<BoundingBox> boxes;
    switch (config.output_layout) {
    case YoloOutputLayout::CenterObjectnessScores:
        if (values < 5) { return std::unexpected(OnnxError::InvalidOutputShape); }
        boxes = decode_center_rows(data, rows, values, config, scale);
        break;
    case YoloOutputLayout::CornersScoreClass:
        if (values < 6) { return std::unexpected(OnnxError::InvalidOutputShape); }
        boxes = decode_corner_rows(data, rows, values, config, scale);
        break;
    case YoloOutputLayout::CenterScoresByAnchor:
        // Here the rows are channels: four box values, then exactly one per configured class.
        if (config.num_classes < 0 || rows != 4 + static_cast<std::size_t>(config.num_classes)) {
            return std::unexpected(OnnxError::InvalidOutputShape);
        }
        boxes = decode_anchor_columns(data, values, config, scale);
        break;
    case YoloOutputLayout::Auto:
        return std::unexpected(OnnxError::InvalidOutputShape);
    }
    apply_nms(boxes, config.nms_threshold);
    return boxes;
}

auto preprocess_frame(const gstreamer::BufferInfo &buffer,
  std::uint32_t width,
  std::uint32_t height,
  FramePreprocessMode mode) -> std::expected<PreprocessedFrame, OnnxError>
{
    const auto &meta = buffer.metadata;
    if (width == 0 || height == 0 || meta.width == 0 || meta.height == 0 || meta.row_stride_bytes < 0) {
        return std::unexpected(OnnxError::InvalidInputShape);
    }
    const std::size_t channels = meta.format == "RGB" ? 3 : (meta.format == "RGBA" ? 4 : 0);
    if (channels == 0) { return std::unexpected(OnnxError::InvalidInputType); }
    const auto max_size = std::numeric_limits<std::size_t>::max();
    if (meta.width > max_size / channels || width > max_size / height / 3) {
        return std::unexpected(OnnxError::InvalidInputShape);
    }
    const auto row_bytes = static_cast<std::size_t>(meta.width) * channels;
    const auto stride = meta.row_stride_bytes == 0 ? row_bytes : static_cast<std::size_t>(meta.row_stride_bytes);
    if (stride < row_bytes || meta.plane_offset_bytes > buffer.size || row_bytes > buffer.size - meta.plane_offset_bytes
        || buffer.data.size() < buffer.size
        || static_cast<std::size_t>(meta.height - 1) > (buffer.size - meta.plane_offset_bytes - row_bytes) / stride) {
        return std::unexpected(OnnxError::InvalidInputShape);
    }
    std::uint32_t content_width = width;
    std::uint32_t content_height = height;
    if (mode == FramePreprocessMode::Letterbox) {
        const auto ratio = std::min(static_cast<double>(width) / meta.width, static_cast<double>(height) / meta.height);
        content_width = std::clamp(static_cast<std::uint32_t>(std::round(meta.width * ratio)), 1U, width);
        content_height = std::clamp(static_cast<std::uint32_t>(std::round(meta.height * ratio)), 1U, height);
    }
    const auto pad_x = (width - content_width) / 2;
    const auto pad_y = (height - content_height) / 2;
    const auto plane = static_cast<std::size_t>(width) * height;
    PreprocessedFrame result;
    result.mapping = { static_cast<float>(content_width) / meta.width,
        static_cast<float>(content_height) / meta.height,
        static_cast<float>(pad_x),
        static_cast<float>(pad_y) };
    result.data.assign(3 * plane, mode == FramePreprocessMode::Letterbox ? 114.0F / 255.0F : 0.0F);
    for (std::uint32_t y = 0; y < content_height; ++y) {
        const auto source_y = static_cast<std::uint64_t>(y) * meta.height / content_height;
        for (std::uint32_t x = 0; x < content_width; ++x) {
            const auto source_x = static_cast<std::uint64_t>(x) * meta.width / content_width;
            const auto source = meta.plane_offset_bytes + static_cast<std::size_t>(source_y) * stride
                                + static_cast<std::size_t>(source_x) * channels;
            const auto destination = static_cast<std::size_t>(y + pad_y) * width + x + pad_x;
            for (std::size_t channel = 0; channel < 3; ++channel) {
                result.data[channel * plane + destination] =
                  std::to_integer<unsigned char>(buffer.data[source + channel]) / 255.0F;
            }
        }
    }
    return result;
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

    if (config.output_layout == YoloOutputLayout::Auto) {
        const auto named = impl_->engine.get_custom_metadata("kataglyphis.output");
        const auto layout = named ? layout_from_metadata(*named) : std::nullopt;
        if (!layout) { return std::unexpected(OnnxError::InvalidOutputShape); }
        impl_->config.output_layout = *layout;
    }

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
        0.0F };
    return post_process(result.value(), width, height, mapping);
}

auto YoloDetector::detect_from_gstreamer(gstreamer::GStreamerPipeline &pipeline, std::uint32_t timeout_ms)
  -> std::expected<DetectionResult, OnnxError>
{
    if (!is_initialized()) { return std::unexpected(OnnxError::SessionNotInitialized); }

    auto buffer_result = pipeline.pull_sample(timeout_ms);
    if (!buffer_result) { return std::unexpected(OnnxError::InputAllocationFailed); }

    return detect_frame(*buffer_result);
}

auto YoloDetector::detect_frame(const gstreamer::BufferInfo &frame) -> std::expected<DetectionResult, OnnxError>
{
    const std::shared_lock lock(impl_->mutex);
    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }
    auto input =
      preprocess_frame(frame, impl_->config.input_width, impl_->config.input_height, impl_->config.preprocess_mode);
    if (!input) { return std::unexpected(input.error()); }
    inference::TensorShape shape{ { 1, 3, impl_->config.input_height, impl_->config.input_width } };
    auto result = impl_->engine.run_inference(input->data, shape, "images");
    if (!result) { return std::unexpected(result.error()); }
    return post_process(*result, frame.metadata.width, frame.metadata.height, input->mapping);
}

auto YoloDetector::post_process(const inference::InferenceResult &raw_output,
  std::uint32_t original_width,
  std::uint32_t original_height,
  const FrameMapping &mapping) -> std::expected<DetectionResult, OnnxError>
{
    DetectionResult result;
    result.original_width = original_width;
    result.original_height = original_height;
    result.inference_time_ms = raw_output.inference_time_ms;
    if (raw_output.outputs.empty()) { return result; }
    auto boxes = decode_detections(raw_output.outputs[0], impl_->config, mapping);
    if (!boxes) { return std::unexpected(boxes.error()); }
    result.boxes = std::move(*boxes);
    return result;
}

auto YoloDetector::get_coco_class_name(int class_id) -> std::string_view
{
    if (class_id >= 0 && std::cmp_less(class_id, COCO_CLASSES.size())) { return COCO_CLASSES[class_id]; }
    return "unknown";
}

struct VideoDetectorPipeline::Impl
{
    YoloDetector detector;
    mutable std::mutex callback_mutex;
    std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> detection_callback;
    std::function<void(const gstreamer::BufferInfo &)> frame_callback;
    std::function<void(OnnxError)> error_callback;
    std::optional<OnnxError> last_error;
    std::atomic<bool> running{ false };
    std::mutex lifecycle_mutex;
    bool starting{ false };
    bool stopping{ false };
    VideoDetectionConfig config;
    // Last, so it is destroyed first: its streaming thread calls into every member above.
    gstreamer::GStreamerPipeline pipeline;

    void on_frame_received(const gstreamer::BufferInfo &buffer)
    {
        std::function<void(const gstreamer::BufferInfo &)> on_frame;
        std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> on_detection;
        {
            const std::scoped_lock lock(callback_mutex);
            on_frame = frame_callback;
            on_detection = detection_callback;
        }
        if (on_frame) { on_frame(buffer); }
        auto detection = detector.detect_frame(buffer);
        if (detection) {
            if (on_detection) { on_detection(*detection, buffer); }
            return;
        }
        std::function<void(OnnxError)> on_error;
        bool changed = false;
        {
            const std::scoped_lock lock(callback_mutex);
            changed = last_error != detection.error();
            last_error = detection.error();
            on_error = error_callback;
        }
        if (on_error) {
            on_error(detection.error());
        } else if (changed) {
            log::error("Video detection failed: {}", static_cast<int>(detection.error()));
        }
    }
};

VideoDetectorPipeline::VideoDetectorPipeline() : impl_(std::make_unique<Impl>()) {}

VideoDetectorPipeline::~VideoDetectorPipeline() = default;

VideoDetectorPipeline::VideoDetectorPipeline(VideoDetectorPipeline &&) noexcept = default;

auto VideoDetectorPipeline::operator=(VideoDetectorPipeline &&) noexcept -> VideoDetectorPipeline & = default;

auto VideoDetectorPipeline::initialize(const VideoDetectionConfig &config) -> std::expected<void, OnnxError>
{ return initialize(config, {}); }

auto VideoDetectorPipeline::initialize(const VideoDetectionConfig &config,
  const std::filesystem::path &profiling_prefix) -> std::expected<void, OnnxError>
{

    impl_->config = config;

    auto init_result = gstreamer::GStreamerPipeline::initialize_gstreamer();
    if (!init_result) { return std::unexpected(OnnxError::SessionCreationFailed); }

    auto detector_result = impl_->detector.initialize(config.yolo_config, profiling_prefix);
    if (!detector_result) { return std::unexpected(detector_result.error()); }

    auto pipeline_result = impl_->pipeline.create_pipeline(config.gstreamer_config);
    if (!pipeline_result) { return std::unexpected(OnnxError::SessionCreationFailed); }

    // The Impl, not `this`: the factories return the pipeline by move, which leaves `this` behind.
    impl_->pipeline.set_buffer_callback(
      [impl = impl_.get()](const gstreamer::BufferInfo &buffer) -> void { impl->on_frame_received(buffer); });

    return {};
}

auto VideoDetectorPipeline::start() -> std::expected<void, gstreamer::GStreamerError>
{
    {
        const std::scoped_lock lifecycle_lock(impl_->lifecycle_mutex);
        if (impl_->starting || impl_->stopping) {
            return std::unexpected(gstreamer::GStreamerError::StateChangeFailed);
        }
        impl_->starting = true;
    }
    {
        const std::scoped_lock lock(impl_->callback_mutex);
        impl_->last_error.reset();
    }
    auto result = impl_->pipeline.start();
    {
        const std::scoped_lock lifecycle_lock(impl_->lifecycle_mutex);
        if (result) { impl_->running.store(true); }
        impl_->starting = false;
    }
    return result;
}

auto VideoDetectorPipeline::stop() -> std::expected<void, gstreamer::GStreamerError>
{
    {
        const std::scoped_lock lifecycle_lock(impl_->lifecycle_mutex);
        if (impl_->starting || impl_->stopping) {
            return std::unexpected(gstreamer::GStreamerError::StateChangeFailed);
        }
        impl_->stopping = true;
    }
    auto result = impl_->pipeline.stop();
    {
        const std::scoped_lock lifecycle_lock(impl_->lifecycle_mutex);
        if (result) { impl_->running.store(false); }
        impl_->stopping = false;
    }
    return result;
}

auto VideoDetectorPipeline::pause() -> std::expected<void, gstreamer::GStreamerError>
{ return impl_->pipeline.pause(); }

auto VideoDetectorPipeline::set_detection_callback(
  std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> callback) -> void
{
    const std::scoped_lock lock(impl_->callback_mutex);
    impl_->detection_callback = std::move(callback);
}

auto VideoDetectorPipeline::set_frame_callback(std::function<void(const gstreamer::BufferInfo &)> callback) -> void
{
    const std::scoped_lock lock(impl_->callback_mutex);
    impl_->frame_callback = std::move(callback);
}

auto VideoDetectorPipeline::set_error_callback(std::function<void(OnnxError)> callback) -> void
{
    const std::scoped_lock lock(impl_->callback_mutex);
    impl_->error_callback = std::move(callback);
}

auto VideoDetectorPipeline::last_error() const -> std::optional<OnnxError>
{
    const std::scoped_lock lock(impl_->callback_mutex);
    return impl_->last_error;
}

auto VideoDetectorPipeline::is_running() const -> bool { return impl_->running.load(); }

auto VideoDetectorPipeline::end_profiling() -> std::expected<std::string, OnnxError>
{
    const std::scoped_lock lifecycle_lock(impl_->lifecycle_mutex);
    if (impl_->running.load() || impl_->starting || impl_->stopping) {
        return std::unexpected(OnnxError::ProfilingFailed);
    }
    return impl_->detector.end_profiling();
}

auto create_camera_detection_pipeline(const std::string &device,
  const std::filesystem::path &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    YoloConfig config;
    config.model_path = model_path;
    return create_camera_detection_pipeline(device, config, width, height, fps);
}

auto create_camera_detection_pipeline(const std::string &device,
  const YoloConfig &yolo_config,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    VideoDetectorPipeline pipeline;
    VideoDetectionConfig config;

    config.yolo_config = yolo_config;

    config.gstreamer_config.pipeline_description =
      build_camera_detection_pipeline_description(device, width, height, fps);

    config.gstreamer_config.enable_tensor_meta = true;

    auto result = pipeline.initialize(config);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

auto create_video_detection_pipeline(const std::string &video_source,
  const std::filesystem::path &model_path,
  std::uint32_t width,
  std::uint32_t height) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    YoloConfig config;
    config.model_path = model_path;
    return create_video_detection_pipeline(video_source, config, width, height);
}

auto create_video_detection_pipeline(const std::string &video_source,
  const YoloConfig &yolo_config,
  std::uint32_t width,
  std::uint32_t height) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    VideoDetectorPipeline pipeline;
    VideoDetectionConfig config;

    config.yolo_config = yolo_config;

    config.gstreamer_config.pipeline_description =
      build_video_detection_pipeline_description(video_source, width, height);
    config.gstreamer_config.enable_tensor_meta = true;

    auto result = pipeline.initialize(config);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

}// namespace kataglyphis::detection
