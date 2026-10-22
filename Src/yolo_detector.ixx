module;

#include "kataglyphis_export.h"
#include <expected>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

export module kataglyphis.yolo_detector;

import kataglyphis.onnx_inference;
import kataglyphis.gstreamer_pipeline;

export namespace kataglyphis::detection {

using OnnxError = inference::OnnxError;

struct BoundingBox
{
    float x{ 0.0F };
    float y{ 0.0F };
    float width{ 0.0F };
    float height{ 0.0F };
    float confidence{ 0.0F };
    int class_id{ -1 };
    std::string class_name;
};

struct DetectionResult
{
    std::vector<BoundingBox> boxes;
    std::vector<float> class_confidences;
    double inference_time_ms{ 0.0 };
    std::uint32_t original_width{ 0 };
    std::uint32_t original_height{ 0 };
};

// How the model's output rows are laid out; the export decides, so the caller names it.
enum class YoloOutputLayout {
    CenterObjectnessScores,// YOLOv5: cx, cy, w, h, objectness, one score per class
    CornersScoreClass,// end-to-end exports (DEIM, YOLOv10): x1, y1, x2, y2, score, class index
};

enum class FramePreprocessMode { Stretch, Letterbox };

struct FrameMapping
{
    float scale_x{ 1.0F };
    float scale_y{ 1.0F };
    float pad_x{ 0.0F };
    float pad_y{ 0.0F };
};

struct PreprocessedFrame
{
    std::vector<float> data;
    FrameMapping mapping;
};

[[nodiscard]] KATAGLYPHIS_CPP_API auto preprocess_frame(const gstreamer::BufferInfo &buffer,
  std::uint32_t width,
  std::uint32_t height,
  FramePreprocessMode mode = FramePreprocessMode::Stretch) -> std::expected<PreprocessedFrame, OnnxError>;

struct YoloConfig
{
    std::filesystem::path model_path;
    float confidence_threshold{ 0.25F };
    float nms_threshold{ 0.45F };
    std::uint32_t input_width{ 640 };
    std::uint32_t input_height{ 640 };
    int num_classes{ 80 };
    YoloOutputLayout output_layout{ YoloOutputLayout::CenterObjectnessScores };
    FramePreprocessMode preprocess_mode{ FramePreprocessMode::Stretch };
};

class KATAGLYPHIS_CPP_API YoloDetector
{
  public:
    YoloDetector();
    ~YoloDetector();

    YoloDetector(const YoloDetector &) = delete;
    auto operator=(const YoloDetector &) -> YoloDetector & = delete;
    YoloDetector(YoloDetector && /*other*/) noexcept;
    auto operator=(YoloDetector && /*other*/) noexcept -> YoloDetector &;

    [[nodiscard]] auto initialize(const YoloConfig &config) -> std::expected<void, OnnxError>;

    [[nodiscard]] auto is_initialized() const -> bool;

    [[nodiscard]] auto detect(std::span<const float> image_data, std::uint32_t width, std::uint32_t height)
      -> std::expected<DetectionResult, OnnxError>;

    [[nodiscard]] auto detect_from_gstreamer(gstreamer::GStreamerPipeline &pipeline, std::uint32_t timeout_ms = 5000)
      -> std::expected<DetectionResult, OnnxError>;

    [[nodiscard]] auto detect_frame(const gstreamer::BufferInfo &frame) -> std::expected<DetectionResult, OnnxError>;

    static auto get_coco_class_name(int class_id) -> std::string_view;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    auto post_process(const inference::InferenceResult &raw_output,
      std::uint32_t original_width,
      std::uint32_t original_height,
      const FrameMapping &mapping) -> DetectionResult;

    auto apply_nms(std::vector<BoundingBox> &boxes, float nms_threshold) -> void;

    static auto calculate_iou(const BoundingBox &a, const BoundingBox &b) -> float;
};

struct VideoDetectionConfig
{
    YoloConfig yolo_config;
    gstreamer::PipelineConfig gstreamer_config;
    bool display_results{ false };
    bool save_to_file{ false };
    std::filesystem::path output_path{ "output.mp4" };
};

class KATAGLYPHIS_CPP_API VideoDetectorPipeline
{
  public:
    VideoDetectorPipeline();
    ~VideoDetectorPipeline();

    VideoDetectorPipeline(const VideoDetectorPipeline &) = delete;
    auto operator=(const VideoDetectorPipeline &) -> VideoDetectorPipeline & = delete;
    VideoDetectorPipeline(VideoDetectorPipeline && /*other*/) noexcept;
    auto operator=(VideoDetectorPipeline && /*other*/) noexcept -> VideoDetectorPipeline &;

    [[nodiscard]] auto initialize(const VideoDetectionConfig &config) -> std::expected<void, OnnxError>;

    [[nodiscard]] auto start() -> std::expected<void, gstreamer::GStreamerError>;
    [[nodiscard]] auto stop() -> std::expected<void, gstreamer::GStreamerError>;
    [[nodiscard]] auto pause() -> std::expected<void, gstreamer::GStreamerError>;

    auto set_detection_callback(std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> callback)
      -> void;

    auto set_frame_callback(std::function<void(const gstreamer::BufferInfo &)> callback) -> void;

    auto set_error_callback(std::function<void(OnnxError)> callback) -> void;
    [[nodiscard]] auto last_error() const -> std::optional<OnnxError>;

    [[nodiscard]] auto is_running() const -> bool;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_camera_detection_pipeline(const std::string &device,
  const std::filesystem::path &model_path,
  std::uint32_t width = 640,
  std::uint32_t height = 480,
  std::uint32_t fps = 30) -> std::expected<VideoDetectorPipeline, OnnxError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_video_detection_pipeline(const std::string &video_source,
  const std::filesystem::path &model_path,
  std::uint32_t width = 640,
  std::uint32_t height = 480) -> std::expected<VideoDetectorPipeline, OnnxError>;

}// namespace kataglyphis::detection
