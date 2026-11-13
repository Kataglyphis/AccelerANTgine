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
import kataglyphis.toml_config;

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
    CenterScoresByAnchor,// YOLOv8 and YOLO11: [1, 4 + classes, anchors], each column cx, cy, w, h, class scores
    Auto,// the model's kataglyphis.output metadata decides; a model without it fails initialize
};

// The layout a kataglyphis.output metadata value names, or nothing for an unknown value.
[[nodiscard]] KATAGLYPHIS_CPP_API auto layout_from_metadata(std::string_view value) -> std::optional<YoloOutputLayout>;

enum class FramePreprocessMode { Stretch, Letterbox };

// How a frame was fitted into the model input, and its size; a size of zero is unset and decode_detections refuses it.
struct FrameMapping
{
    float scale_x{ 1.0F };
    float scale_y{ 1.0F };
    float pad_x{ 0.0F };
    float pad_y{ 0.0F };
    std::uint32_t frame_width{ 0 };
    std::uint32_t frame_height{ 0 };
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
    inference::ExecutionProvider execution_provider{ inference::ExecutionProvider::Cpu };
    int device_id = 0;
    // One thread each makes an instruction count repeatable (the cachegrind check); the defaults are the engine's.
    int intra_op_num_threads{ 4 };
    int inter_op_num_threads{ 4 };
    // Names by class index; empty keeps the built-in COCO names.
    std::vector<std::string> labels;
};

// A detector config from the [model] table; an unknown output_layout is InvalidValue, unset keeps the default.
[[nodiscard]] KATAGLYPHIS_CPP_API auto yolo_config_from(const config::ModelConfig &model)
  -> std::expected<YoloConfig, config::ConfigError>;

// Raw rows to boxes cut to mapping's frame; the two raw layouts suppress overlaps first, corner rows are one per object.
[[nodiscard]] KATAGLYPHIS_CPP_API auto decode_detections(const inference::TensorData &output,
  const YoloConfig &config,
  const FrameMapping &mapping) -> std::expected<std::vector<BoundingBox>, OnnxError>;

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

    [[nodiscard]] auto initialize(const YoloConfig &config, const std::filesystem::path &profiling_prefix)
      -> std::expected<void, OnnxError>;

    [[nodiscard]] auto is_initialized() const -> bool;

    [[nodiscard]] auto end_profiling() -> std::expected<std::string, OnnxError>;

    // The layout initialize settled on, Auto resolved from the model.
    [[nodiscard]] auto output_layout() const -> YoloOutputLayout;

    // The intra-op thread count the ORT session options were given.
    [[nodiscard]] auto applied_intra_op_num_threads() const -> int;

    [[nodiscard]] auto detect(std::span<const float> image_data, std::uint32_t width, std::uint32_t height)
      -> std::expected<DetectionResult, OnnxError>;

    [[nodiscard]] auto detect_from_gstreamer(gstreamer::GStreamerPipeline &pipeline, std::uint32_t timeout_ms = 5000)
      -> std::expected<DetectionResult, OnnxError>;

    [[nodiscard]] auto detect_frame(const gstreamer::BufferInfo &frame) -> std::expected<DetectionResult, OnnxError>;

    static auto get_coco_class_name(int class_id) -> std::string_view;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    auto post_process(const inference::InferenceResult &raw_output, const FrameMapping &mapping)
      -> std::expected<DetectionResult, OnnxError>;
};

struct VideoDetectionConfig
{
    YoloConfig yolo_config;
    gstreamer::PipelineConfig gstreamer_config;
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

    [[nodiscard]] auto initialize(const VideoDetectionConfig &config, const std::filesystem::path &profiling_prefix)
      -> std::expected<void, OnnxError>;

    [[nodiscard]] auto start() -> std::expected<void, gstreamer::GStreamerError>;
    [[nodiscard]] auto stop() -> std::expected<void, gstreamer::GStreamerError>;
    [[nodiscard]] auto pause() -> std::expected<void, gstreamer::GStreamerError>;

    auto set_detection_callback(std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> callback)
      -> void;

    auto set_frame_callback(std::function<void(const gstreamer::BufferInfo &)> callback) -> void;

    auto set_error_callback(std::function<void(OnnxError)> callback) -> void;
    [[nodiscard]] auto last_error() const -> std::optional<OnnxError>;

    [[nodiscard]] auto is_running() const -> bool;

    // The callbacks only fire for frames, so a stream that ended on its own is asked for here.
    [[nodiscard]] auto has_ended() const -> bool;
    [[nodiscard]] auto stream_error() const -> std::optional<std::string>;

    [[nodiscard]] auto end_profiling() -> std::expected<std::string, OnnxError>;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] KATAGLYPHIS_CPP_API auto camera_detection_pipeline_description(const std::string &device,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::string;

[[nodiscard]] KATAGLYPHIS_CPP_API auto video_detection_pipeline_description(const std::string &video_source,
  std::uint32_t width,
  std::uint32_t height) -> std::string;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_camera_detection_pipeline(const std::string &device,
  const std::filesystem::path &model_path,
  std::uint32_t width = 640,
  std::uint32_t height = 480,
  std::uint32_t fps = 30) -> std::expected<VideoDetectorPipeline, OnnxError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_camera_detection_pipeline(const std::string &device,
  const YoloConfig &config,
  std::uint32_t width = 640,
  std::uint32_t height = 480,
  std::uint32_t fps = 30) -> std::expected<VideoDetectorPipeline, OnnxError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_video_detection_pipeline(const std::string &video_source,
  const std::filesystem::path &model_path,
  std::uint32_t width = 640,
  std::uint32_t height = 480) -> std::expected<VideoDetectorPipeline, OnnxError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_video_detection_pipeline(const std::string &video_source,
  const YoloConfig &config,
  std::uint32_t width = 640,
  std::uint32_t height = 480) -> std::expected<VideoDetectorPipeline, OnnxError>;

}// namespace kataglyphis::detection
