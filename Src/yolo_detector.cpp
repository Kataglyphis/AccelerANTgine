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
#include <shared_mutex>
#include <span>
#include <utility>

module kataglyphis.yolo_detector;

import kataglyphis.onnx_inference;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.project_config;

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

    auto labelled_box(float x, float y, float width, float height, float confidence, int class_id) -> BoundingBox
    {
        BoundingBox box;
        box.x = x;
        box.y = y;
        box.width = width;
        box.height = height;
        box.confidence = confidence;
        box.class_id = class_id;
        box.class_name = YoloDetector::get_coco_class_name(class_id);
        return box;
    }

    auto decode_center_rows(std::span<const float> data,
      std::size_t rows,
      std::size_t values,
      const YoloConfig &config,
      Scale scale) -> std::vector<BoundingBox>
    {
        std::vector<BoundingBox> boxes;
        // A row is cx, cy, w, h, objectness, then class scores; anything shorter is not a detection layout.
        if (values < 5) { return boxes; }
        // Class scores beyond the row would be read from the next detection.
        const std::size_t class_count = std::min(static_cast<std::size_t>(std::max(config.num_classes, 0)), values - 5);

        for (std::size_t i = 0; i < rows && (i + 1) * values <= data.size(); ++i) {
            const auto row = data.subspan(i * values, values);
            const float cx = row[0];
            const float cy = row[1];
            const float w = row[2];
            const float h = row[3];
            const float obj_conf = row[4];

            // NaN fails every comparison, so the thresholds test for acceptance, not rejection.
            if (!(obj_conf >= config.confidence_threshold)) { continue; }
            if (!std::isfinite(cx) || !std::isfinite(cy) || !std::isfinite(w) || !std::isfinite(h)) { continue; }

            int best_class = 0;
            float final_conf = obj_conf;
            if (class_count > 0) {
                float best_class_conf = 0.0F;
                for (std::size_t c = 0; c < class_count; ++c) {
                    if (row[5 + c] > best_class_conf) {
                        best_class_conf = row[5 + c];
                        best_class = static_cast<int>(c);
                    }
                }
                final_conf = obj_conf * best_class_conf;
            }
            if (!(final_conf >= config.confidence_threshold) || !std::isfinite(final_conf)) { continue; }

            boxes.push_back(labelled_box((cx - (w / 2.0F)) * scale.x - scale.offset_x,
              (cy - (h / 2.0F)) * scale.y - scale.offset_y,
              w * scale.x,
              h * scale.y,
              final_conf,
              best_class));
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
        if (values < 6) { return boxes; }
        for (std::size_t i = 0; i < rows && (i + 1) * values <= data.size(); ++i) {
            const auto row = data.subspan(i * values, values);
            if (!corner_row_is_usable(row, config)) { continue; }
            boxes.push_back(labelled_box(row[0] * scale.x - scale.offset_x,
              row[1] * scale.y - scale.offset_y,
              (row[2] - row[0]) * scale.x,
              (row[3] - row[1]) * scale.y,
              row[4],
              static_cast<int>(row[5])));
        }
        return boxes;
    }
}// namespace

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
{
    const std::unique_lock lock(impl_->mutex);
    impl_->initialized = false;
    if (config.input_width == 0 || config.input_height == 0) { return std::unexpected(OnnxError::InvalidInputShape); }
    impl_->config = config;

    auto session_config = inference::create_default_session_config(config.model_path);

    auto result = impl_->engine.initialize(session_config);
    if (!result) { return std::unexpected(result.error()); }

    impl_->initialized = true;
    return {};
}

auto YoloDetector::is_initialized() const -> bool
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->initialized;
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
  const FrameMapping &mapping) -> DetectionResult
{

    DetectionResult result;
    result.original_width = original_width;
    result.original_height = original_height;
    result.inference_time_ms = raw_output.inference_time_ms;

    if (raw_output.outputs.empty()) { return result; }

    const auto &output = raw_output.outputs[0];
    const auto &dims = output.shape.dimensions;
    if (dims.empty()) { return result; }

    std::size_t num_detections = dims[0];
    std::size_t values_per_detection = dims.size() > 1 ? dims[1] : dims[0];

    if (dims.size() == 3) {
        num_detections = dims[1];
        values_per_detection = dims[2];
    }

    const std::span<const float> data(output.data.data(), output.data.size());
    const Scale scale{
        1.0F / mapping.scale_x, 1.0F / mapping.scale_y, mapping.pad_x / mapping.scale_x, mapping.pad_y / mapping.scale_y
    };
    auto all_boxes = impl_->config.output_layout == YoloOutputLayout::CornersScoreClass
                       ? decode_corner_rows(data, num_detections, values_per_detection, impl_->config, scale)
                       : decode_center_rows(data, num_detections, values_per_detection, impl_->config, scale);

    apply_nms(all_boxes, impl_->config.nms_threshold);

    result.boxes = std::move(all_boxes);
    return result;
}

auto YoloDetector::apply_nms(std::vector<BoundingBox> &boxes, float nms_threshold) -> void
{

    std::ranges::sort(
      boxes, [](const BoundingBox &a, const BoundingBox &b) -> bool { return a.confidence > b.confidence; });

    std::vector<bool> suppressed(boxes.size(), false);

    for (std::size_t i = 0; i < boxes.size(); ++i) {
        if (suppressed[i]) { continue; }

        for (std::size_t j = i + 1; j < boxes.size(); ++j) {
            if (suppressed[j]) { continue; }

            if (boxes[i].class_id == boxes[j].class_id) {
                float iou = calculate_iou(boxes[i], boxes[j]);
                if (iou > nms_threshold) { suppressed[j] = true; }
            }
        }
    }

    std::vector<BoundingBox> kept;
    for (std::size_t i = 0; i < boxes.size(); ++i) {
        if (!suppressed[i]) { kept.push_back(std::move(boxes[i])); }
    }
    boxes = std::move(kept);
}

auto YoloDetector::calculate_iou(const BoundingBox &a, const BoundingBox &b) -> float
{

    float x1 = std::max(a.x, b.x);
    float y1 = std::max(a.y, b.y);
    float x2 = std::min(a.x + a.width, b.x + b.width);
    float y2 = std::min(a.y + a.height, b.y + b.height);

    if (x2 <= x1 || y2 <= y1) { return 0.0F; }

    float intersection = (x2 - x1) * (y2 - y1);
    float area_a = a.width * a.height;
    float area_b = b.width * b.height;
    float union_area = area_a + area_b - intersection;

    return intersection / union_area;
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
            std::fprintf(stderr, "Video detection failed: %d\n", static_cast<int>(detection.error()));
        }
    }
};

VideoDetectorPipeline::VideoDetectorPipeline() : impl_(std::make_unique<Impl>()) {}

VideoDetectorPipeline::~VideoDetectorPipeline() = default;

VideoDetectorPipeline::VideoDetectorPipeline(VideoDetectorPipeline &&) noexcept = default;

auto VideoDetectorPipeline::operator=(VideoDetectorPipeline &&) noexcept -> VideoDetectorPipeline & = default;

auto VideoDetectorPipeline::initialize(const VideoDetectionConfig &config) -> std::expected<void, OnnxError>
{

    impl_->config = config;

    auto init_result = gstreamer::GStreamerPipeline::initialize_gstreamer();
    if (!init_result) { return std::unexpected(OnnxError::SessionCreationFailed); }

    auto detector_result = impl_->detector.initialize(config.yolo_config);
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
        const std::scoped_lock lock(impl_->callback_mutex);
        impl_->last_error.reset();
    }
    auto result = impl_->pipeline.start();
    if (result) { impl_->running.store(true); }
    return result;
}

auto VideoDetectorPipeline::stop() -> std::expected<void, gstreamer::GStreamerError>
{
    impl_->running.store(false);
    return impl_->pipeline.stop();
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

auto create_camera_detection_pipeline(const std::string &device,
  const std::filesystem::path &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<VideoDetectorPipeline, OnnxError>
{

    VideoDetectorPipeline pipeline;
    VideoDetectionConfig config;

    config.yolo_config.model_path = model_path;

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

    VideoDetectorPipeline pipeline;
    VideoDetectionConfig config;

    config.yolo_config.model_path = model_path;

    config.gstreamer_config.pipeline_description =
      build_video_detection_pipeline_description(video_source, width, height);
    config.gstreamer_config.enable_tensor_meta = true;

    auto result = pipeline.initialize(config);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

}// namespace kataglyphis::detection
