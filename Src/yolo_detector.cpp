module;

#include "kataglyphis_export.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <expected>
#include <filesystem>
#include <functional>
#include <numeric>

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
}

struct YoloDetector::Impl
{
    inference::OnnxInferenceEngine engine;
    YoloConfig config;
    bool initialized{ false };
};

YoloDetector::YoloDetector() : impl_(std::make_unique<Impl>()) {}

YoloDetector::~YoloDetector() = default;

YoloDetector::YoloDetector(YoloDetector &&other) noexcept : impl_(std::move(other.impl_)) {}

YoloDetector &YoloDetector::operator=(YoloDetector &&other) noexcept
{
    if (this != &other) { impl_ = std::move(other.impl_); }
    return *this;
}

auto YoloDetector::initialize(const YoloConfig &config) -> std::expected<void, OnnxError>
{

    impl_->config = config;

    inference::SessionConfig session_config;
    session_config.model_path = config.model_path;
    session_config.intra_op_num_threads = 4;
    session_config.inter_op_num_threads = 4;
    session_config.enable_cuda = false;
    session_config.execution_mode = "sequential";

    auto result = impl_->engine.initialize(session_config);
    if (!result) { return std::unexpected(result.error()); }

    impl_->initialized = true;
    return {};
}

auto YoloDetector::is_initialized() const -> bool { return impl_->initialized; }

auto YoloDetector::detect(std::span<const float> image_data, std::uint32_t width, std::uint32_t height)
  -> std::expected<DetectionResult, OnnxError>
{

    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    inference::TensorShape input_shape;
    input_shape.dimensions = { 1, 3, impl_->config.input_height, impl_->config.input_width };

    auto result = impl_->engine.run_inference(image_data, input_shape, "images");

    if (!result) { return std::unexpected(result.error()); }

    return post_process(result.value(), width, height);
}

auto YoloDetector::detect_from_gstreamer(gstreamer::GStreamerPipeline &pipeline, std::uint32_t timeout_ms)
  -> std::expected<DetectionResult, OnnxError>
{

    if (!impl_->initialized) { return std::unexpected(OnnxError::SessionNotInitialized); }

    auto buffer_result = pipeline.pull_sample(timeout_ms);
    if (!buffer_result) { return std::unexpected(OnnxError::InputAllocationFailed); }

    const auto &buffer_info = buffer_result.value();
    const float *data = static_cast<const float *>(buffer_info.data);
    std::size_t size = buffer_info.size / sizeof(float);

    return detect(std::span<const float>(data, size), buffer_info.metadata.width, buffer_info.metadata.height);
}

auto YoloDetector::post_process(const inference::InferenceResult &raw_output,
  std::uint32_t original_width,
  std::uint32_t original_height) -> DetectionResult
{

    DetectionResult result;
    result.original_width = original_width;
    result.original_height = original_height;
    result.inference_time_ms = raw_output.inference_time_ms;

    if (raw_output.outputs.empty()) { return result; }

    const auto &output = raw_output.outputs[0];
    const auto &dims = output.shape.dimensions;

    std::size_t num_detections = dims[0];
    std::size_t values_per_detection = dims.size() > 1 ? dims[1] : dims[0];

    if (dims.size() == 3) {
        num_detections = dims[1];
        values_per_detection = dims[2];
    }

    const float *data = output.data.data();

    float scale_x = static_cast<float>(original_width) / static_cast<float>(impl_->config.input_width);
    float scale_y = static_cast<float>(original_height) / static_cast<float>(impl_->config.input_height);

    std::vector<BoundingBox> all_boxes;

    for (std::size_t i = 0; i < num_detections; ++i) {
        std::size_t offset = i * values_per_detection;

        float cx = data[offset + 0];
        float cy = data[offset + 1];
        float w = data[offset + 2];
        float h = data[offset + 3];
        float obj_conf = data[offset + 4];

        if (obj_conf < impl_->config.confidence_threshold) { continue; }

        int best_class = 0;
        float best_class_conf = 0.0f;

        if (values_per_detection > 5) {
            for (int c = 0; c < impl_->config.num_classes; ++c) {
                float class_conf = data[offset + 5 + c];
                if (class_conf > best_class_conf) {
                    best_class_conf = class_conf;
                    best_class = c;
                }
            }
        } else {
            best_class_conf = obj_conf;
        }

        float final_conf = obj_conf * best_class_conf;
        if (final_conf < impl_->config.confidence_threshold) { continue; }

        BoundingBox box;
        box.x = (cx - w / 2.0f) * scale_x;
        box.y = (cy - h / 2.0f) * scale_y;
        box.width = w * scale_x;
        box.height = h * scale_y;
        box.confidence = final_conf;
        box.class_id = best_class;
        box.class_name = get_coco_class_name(best_class);

        all_boxes.push_back(box);
    }

    apply_nms(all_boxes, impl_->config.nms_threshold);

    result.boxes = std::move(all_boxes);
    return result;
}

auto YoloDetector::apply_nms(std::vector<BoundingBox> &boxes, float nms_threshold) -> void
{

    std::sort(boxes.begin(), boxes.end(), [](const BoundingBox &a, const BoundingBox &b) {
        return a.confidence > b.confidence;
    });

    std::vector<bool> suppressed(boxes.size(), false);

    for (std::size_t i = 0; i < boxes.size(); ++i) {
        if (suppressed[i]) continue;

        for (std::size_t j = i + 1; j < boxes.size(); ++j) {
            if (suppressed[j]) continue;

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

    if (x2 <= x1 || y2 <= y1) { return 0.0f; }

    float intersection = (x2 - x1) * (y2 - y1);
    float area_a = a.width * a.height;
    float area_b = b.width * b.height;
    float union_area = area_a + area_b - intersection;

    return intersection / union_area;
}

auto YoloDetector::get_coco_class_name(int class_id) -> std::string
{
    if (class_id >= 0 && class_id < static_cast<int>(COCO_CLASSES.size())) { return COCO_CLASSES[class_id]; }
    return "unknown";
}

struct VideoDetectorPipeline::Impl
{
    YoloDetector detector;
    gstreamer::GStreamerPipeline pipeline;
    std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> detection_callback;
    std::function<void(const gstreamer::BufferInfo &)> frame_callback;
    std::atomic<bool> running{ false };
    VideoDetectionConfig config;

    void on_frame_received(const gstreamer::BufferInfo &buffer)
    {
        if (frame_callback) { frame_callback(buffer); }

        if (detector.is_initialized()) {
            auto detection = detector.detect(
              std::span<const float>(static_cast<const float *>(buffer.data), buffer.size / sizeof(float)),
              buffer.metadata.width,
              buffer.metadata.height);

            if (detection && detection_callback) { detection_callback(detection.value(), buffer); }
        }
    }
};

VideoDetectorPipeline::VideoDetectorPipeline() : impl_(std::make_unique<Impl>()) {}

VideoDetectorPipeline::~VideoDetectorPipeline() = default;

VideoDetectorPipeline::VideoDetectorPipeline(VideoDetectorPipeline &&other) noexcept : impl_(std::move(other.impl_)) {}

VideoDetectorPipeline &VideoDetectorPipeline::operator=(VideoDetectorPipeline &&other) noexcept
{
    if (this != &other) { impl_ = std::move(other.impl_); }
    return *this;
}

auto VideoDetectorPipeline::initialize(const VideoDetectionConfig &config) -> std::expected<void, OnnxError>
{

    impl_->config = config;

    auto init_result = gstreamer::GStreamerPipeline::initialize_gstreamer();
    if (!init_result) { return std::unexpected(OnnxError::SessionCreationFailed); }

    auto detector_result = impl_->detector.initialize(config.yolo_config);
    if (!detector_result) { return std::unexpected(detector_result.error()); }

    auto pipeline_result = impl_->pipeline.create_pipeline(config.gstreamer_config);
    if (!pipeline_result) { return std::unexpected(OnnxError::SessionCreationFailed); }

    impl_->pipeline.set_buffer_callback(
      [this](const gstreamer::BufferInfo &buffer) { impl_->on_frame_received(buffer); });

    return {};
}

auto VideoDetectorPipeline::start() -> std::expected<void, gstreamer::GStreamerError>
{
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
{
    return impl_->pipeline.pause();
}

auto VideoDetectorPipeline::set_detection_callback(
  std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> callback) -> void
{
    impl_->detection_callback = std::move(callback);
}

auto VideoDetectorPipeline::set_frame_callback(std::function<void(const gstreamer::BufferInfo &)> callback) -> void
{
    impl_->frame_callback = std::move(callback);
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
    config.yolo_config.input_width = width;
    config.yolo_config.input_height = height;

    config.gstreamer_config.pipeline_description = 
        "v4l2src device=" + device + " ! "
        "video/x-raw,width=" + std::to_string(width) + 
        ",height=" + std::to_string(height) +
        ",framerate=" + std::to_string(fps) + "/1 ! "
        "videoconvert ! video/x-raw,format=RGB ! "
        "appsink name=detector_sink emit-signals=true sync=false";

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
    config.yolo_config.input_width = width;
    config.yolo_config.input_height = height;

    std::string pipeline_desc;

    if (video_source.find("://") != std::string::npos) {
        pipeline_desc = "uridecodebin uri=" + video_source + " ! ";
    } else {
        pipeline_desc = "filesrc location=" + video_source + " ! decodebin ! ";
    }

    pipeline_desc += 
        "videoconvert ! videoscale ! "
        "video/x-raw,format=RGB,width=" + std::to_string(width) + 
        ",height=" + std::to_string(height) + " ! "
        "appsink name=detector_sink emit-signals=true sync=false";

    config.gstreamer_config.pipeline_description = pipeline_desc;
    config.gstreamer_config.enable_tensor_meta = true;

    auto result = pipeline.initialize(config);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

}// namespace kataglyphis::detection