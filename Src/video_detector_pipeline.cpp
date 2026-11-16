// The video pipeline around the detector: its launch lines, its streaming state and the factories.
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

auto camera_detection_pipeline_description(const std::string &device,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::string
{
    return "v4l2src device=" + gstreamer::quote_pipeline_value(device) + " ! "
           + camera_detection_pipeline_tail(width, height, fps);
}

auto camera_detection_pipeline_tail(std::uint32_t width, std::uint32_t height, std::uint32_t fps) -> std::string
{
    // The detector runs on the streaming thread; the leaky queue hands it the newest frame, not the oldest queued one.
    return "video/x-raw,width=" + std::to_string(width) + ",height=" + std::to_string(height)
           + ",framerate=" + std::to_string(fps)
           + "/1 ! "
             "queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 ! "
             "videoconvert ! video/x-raw,format=RGB ! "
             "appsink name=detector_sink emit-signals=true sync=false max-buffers=1 drop=true";
}

auto video_detection_pipeline_description(const std::string &video_source,
  std::uint32_t width,
  std::uint32_t height,
  VideoPace pace) -> std::string
{
    const std::string head =
      video_source.contains("://")
        ? "uridecodebin uri=" + gstreamer::quote_pipeline_value(video_source) + " ! "
        : "filesrc location=" + gstreamer::quote_pipeline_value(video_source) + " ! decodebin ! ";
    return head + video_detection_pipeline_tail(width, height, pace);
}

auto video_detection_pipeline_tail(std::uint32_t width, std::uint32_t height, VideoPace pace) -> std::string
{
    const bool live = pace == VideoPace::Live;
    std::string tail;
    // Live: the camera pipeline's leaky queue and dropping sink, so a slow detector sees the newest frame.
    if (live) { tail += "queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 ! "; }
    tail += "videoconvert ! videoscale ! video/x-raw,format=RGB,width=" + std::to_string(width)
            + ",height=" + std::to_string(height) + " ! appsink name=detector_sink emit-signals=true sync=false";
    if (live) { tail += " max-buffers=1 drop=true"; }
    return tail;
}

namespace {
    // Written by the streaming thread, read by stats() on any.
    class FrameCounter
    {
      public:
        void count(const gstreamer::FrameMetadata &meta, const std::expected<DetectionResult, OnnxError> &detection)
        {
            const std::scoped_lock lock(mutex_);
            if (counted_.frames > 0 && meta.fps_n > 0 && meta.timestamp_ns > counted_.last_timestamp_ns) {
                constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
                const std::uint64_t period = nanoseconds_per_second * meta.fps_d / meta.fps_n;
                // A gap of n periods is n - 1 frames the source made and the leaky queue dropped; half a period is jitter.
                const std::uint64_t gap = meta.timestamp_ns - counted_.last_timestamp_ns;
                const std::uint64_t periods = period == 0 ? 1 : (gap + (period / 2)) / period;
                if (periods > 1) { counted_.dropped += periods - 1; }
            }
            if (counted_.frames == 0) { counted_.first_timestamp_ns = meta.timestamp_ns; }
            counted_.last_timestamp_ns = meta.timestamp_ns;
            ++counted_.frames;
            if (detection) {
                counted_.last_inference_ms = detection->inference_time_ms;
            } else {
                ++counted_.errors;
            }
        }

        [[nodiscard]] auto snapshot() const -> VideoDetectionStats
        {
            const std::scoped_lock lock(mutex_);
            return counted_;
        }

      private:
        mutable std::mutex mutex_;
        VideoDetectionStats counted_;
    };
}// namespace

struct VideoDetectorPipeline::Impl
{
    YoloDetector detector;
    mutable std::mutex callback_mutex;
    // Set by the caller's thread, read by the streaming one, both under callback_mutex.
    struct Callbacks
    {
        std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> detection;
        std::function<void(const gstreamer::BufferInfo &)> frame;
        std::function<void(OnnxError)> error;
    } callbacks;
    std::optional<OnnxError> last_error;
    std::atomic<bool> running{ false };
    std::mutex lifecycle_mutex;
    bool starting{ false };
    bool stopping{ false };
    VideoDetectionConfig config;
    // The streaming thread's own: the model's input it reuses and what it counts, for on_frame_received alone.
    struct Streaming
    {
        PreprocessedFrame scratch;
        FrameCounter counter;
    } streaming;
    // Last, so it is destroyed first: its streaming thread calls into every member above.
    gstreamer::GStreamerPipeline pipeline;

    void on_frame_received(const gstreamer::BufferInfo &buffer)
    {
        std::function<void(const gstreamer::BufferInfo &)> on_frame;
        std::function<void(const DetectionResult &, const gstreamer::BufferInfo &)> on_detection;
        {
            const std::scoped_lock lock(callback_mutex);
            on_frame = callbacks.frame;
            on_detection = callbacks.detection;
        }
        if (on_frame) { on_frame(buffer); }
        auto detection = detector.detect_frame(buffer, streaming.scratch);
        streaming.counter.count(buffer.metadata, detection);
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
            on_error = callbacks.error;
        }
        if (on_error) {
            on_error(detection.error());
        } else if (changed) {
            log::error("Video detection failed: {}", to_string(detection.error()));
        }
    }
};

auto VideoDetectorPipeline::request_stop() -> void { impl_->pipeline.request_stop(); }

auto VideoDetectorPipeline::stats() const -> VideoDetectionStats { return impl_->streaming.counter.snapshot(); }

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
    if (!init_result) { return std::unexpected(OnnxError::MediaInitFailed); }

    auto detector_result = impl_->detector.initialize(config.yolo_config, profiling_prefix);
    if (!detector_result) { return std::unexpected(detector_result.error()); }

    auto pipeline_result = impl_->pipeline.create_pipeline(config.gstreamer_config);
    if (!pipeline_result) { return std::unexpected(OnnxError::PipelineParseFailed); }

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
    impl_->callbacks.detection = std::move(callback);
}

auto VideoDetectorPipeline::set_frame_callback(std::function<void(const gstreamer::BufferInfo &)> callback) -> void
{
    const std::scoped_lock lock(impl_->callback_mutex);
    impl_->callbacks.frame = std::move(callback);
}

auto VideoDetectorPipeline::set_error_callback(std::function<void(OnnxError)> callback) -> void
{
    const std::scoped_lock lock(impl_->callback_mutex);
    impl_->callbacks.error = std::move(callback);
}

auto VideoDetectorPipeline::last_error() const -> std::optional<OnnxError>
{
    const std::scoped_lock lock(impl_->callback_mutex);
    return impl_->last_error;
}

auto VideoDetectorPipeline::is_running() const -> bool { return impl_->running.load(); }

auto VideoDetectorPipeline::has_ended() const -> bool { return impl_->pipeline.has_ended(); }

auto VideoDetectorPipeline::stream_error() const -> std::optional<std::string>
{ return impl_->pipeline.stream_error(); }

auto VideoDetectorPipeline::end_profiling() -> std::expected<std::string, OnnxError>
{
    const std::scoped_lock lifecycle_lock(impl_->lifecycle_mutex);
    if (impl_->running.load() || impl_->starting || impl_->stopping) {
        return std::unexpected(OnnxError::ProfilingFailed);
    }
    return impl_->detector.end_profiling();
}

namespace {
    // With only a path the model says its layout itself; one that names none is read as the legacy default, as before.
    template<typename Build>
    auto with_the_models_layout(const std::filesystem::path &model_path, Build build)
      -> std::expected<VideoDetectorPipeline, OnnxError>
    {
        YoloConfig config;
        config.model_path = model_path;
        config.output_layout = YoloOutputLayout::Auto;
        auto named = build(config);
        if (named || named.error() != OnnxError::InvalidOutputShape) { return named; }
        config.output_layout = YoloConfig{}.output_layout;
        return build(config);
    }
}// namespace

auto create_camera_detection_pipeline(const std::string &device,
  const std::filesystem::path &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    return with_the_models_layout(model_path,
      [&](const YoloConfig &config) { return create_camera_detection_pipeline(device, config, width, height, fps); });
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

    config.gstreamer_config.pipeline_description = camera_detection_pipeline_description(device, width, height, fps);

    auto result = pipeline.initialize(config);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

auto create_video_detection_pipeline(const std::string &video_source,
  const std::filesystem::path &model_path,
  std::uint32_t width,
  std::uint32_t height,
  VideoPace pace) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    return with_the_models_layout(model_path, [&](const YoloConfig &config) {
        return create_video_detection_pipeline(video_source, config, width, height, pace);
    });
}

auto create_video_detection_pipeline(const std::string &video_source,
  const YoloConfig &yolo_config,
  std::uint32_t width,
  std::uint32_t height,
  VideoPace pace) -> std::expected<VideoDetectorPipeline, OnnxError>
{
    VideoDetectorPipeline pipeline;
    VideoDetectionConfig config;

    config.yolo_config = yolo_config;

    config.gstreamer_config.pipeline_description =
      video_detection_pipeline_description(video_source, width, height, pace);

    auto result = pipeline.initialize(config);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

}// namespace kataglyphis::detection
