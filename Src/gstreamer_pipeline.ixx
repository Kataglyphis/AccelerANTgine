module;

#include "kataglyphis_export.h"
#include <cstddef>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

export module kataglyphis.gstreamer_pipeline;

export namespace kataglyphis::gstreamer {

enum class GStreamerError {
    InitializationFailed,
    PipelineCreationFailed,
    ElementCreationFailed,
    LinkFailed,
    StateChangeFailed,
    BufferAllocationFailed,
    CapsNegotiationFailed,
    StreamError,
    InvalidParameter,
    ResourceNotFound
};

// The value's own name, for a log line, a message or a binding; no default, so a new value fails the build here.
[[nodiscard]] constexpr auto to_string(GStreamerError error) noexcept -> std::string_view
{
    switch (error) {
    case GStreamerError::InitializationFailed:
        return "InitializationFailed";
    case GStreamerError::PipelineCreationFailed:
        return "PipelineCreationFailed";
    case GStreamerError::ElementCreationFailed:
        return "ElementCreationFailed";
    case GStreamerError::LinkFailed:
        return "LinkFailed";
    case GStreamerError::StateChangeFailed:
        return "StateChangeFailed";
    case GStreamerError::BufferAllocationFailed:
        return "BufferAllocationFailed";
    case GStreamerError::CapsNegotiationFailed:
        return "CapsNegotiationFailed";
    case GStreamerError::StreamError:
        return "StreamError";
    case GStreamerError::InvalidParameter:
        return "InvalidParameter";
    case GStreamerError::ResourceNotFound:
        return "ResourceNotFound";
    }
    return "UnknownError";
}

struct TensorMeta
{
    std::size_t tensor_index{ 0 };
    std::size_t num_tensors{ 0 };
    std::vector<std::size_t> dimensions;
    int data_type{ 0 };
};

struct FrameMetadata
{
    std::uint32_t width{ 0 };
    std::uint32_t height{ 0 };
    std::uint32_t fps_n{ 0 };
    std::uint32_t fps_d{ 1 };
    std::string format;
    std::uint64_t timestamp_ns{ 0 };
    std::uint64_t duration_ns{ 0 };
    std::int64_t row_stride_bytes{ 0 };
    std::size_t plane_offset_bytes{ 0 };
};

struct BufferInfo
{
    std::vector<std::byte> data;
    std::size_t size{ 0 };
    FrameMetadata metadata;
    std::vector<TensorMeta> tensors;
};

using BufferCallback = std::function<void(const BufferInfo &)>;

struct PipelineConfig
{
    std::string pipeline_description;
    std::uint32_t timeout_ms{ 5000 };
};

class KATAGLYPHIS_CPP_API GStreamerPipeline
{
  public:
    GStreamerPipeline();
    ~GStreamerPipeline();

    GStreamerPipeline(const GStreamerPipeline &) = delete;
    auto operator=(const GStreamerPipeline &) -> GStreamerPipeline & = delete;
    GStreamerPipeline(GStreamerPipeline && /*other*/) noexcept;
    auto operator=(GStreamerPipeline && /*other*/) noexcept -> GStreamerPipeline &;

    [[nodiscard]] static auto initialize_gstreamer(int *argc = nullptr, char ***argv = nullptr)
      -> std::expected<void, GStreamerError>;

    static auto deinitialize_gstreamer() -> void;

    [[nodiscard]] auto create_pipeline(const PipelineConfig &config) -> std::expected<void, GStreamerError>;

    [[nodiscard]] auto create_pipeline_from_string(const std::string &description)
      -> std::expected<void, GStreamerError>;

    [[nodiscard]] auto create_inference_pipeline(const std::string &input_source,
      const std::string &model_path,
      const std::vector<std::size_t> &input_shape,
      const std::string &output_format = "RAW") -> std::expected<void, GStreamerError>;

    [[nodiscard]] auto start() -> std::expected<void, GStreamerError>;
    [[nodiscard]] auto stop() -> std::expected<void, GStreamerError>;
    [[nodiscard]] auto pause() -> std::expected<void, GStreamerError>;

    [[nodiscard]] auto is_playing() const -> bool;

    // True once the stream reached its end or an element reported an error, since the last start.
    [[nodiscard]] auto has_ended() const -> bool;

    // What the first failing element reported, such as a camera that was unplugged or a device that is busy.
    [[nodiscard]] auto stream_error() const -> std::optional<std::string>;

    auto set_buffer_callback(BufferCallback callback) -> void;

    [[nodiscard]] auto pull_sample(std::uint32_t timeout_ms = 5000) -> std::expected<BufferInfo, GStreamerError>;


  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// One gst-launch property value, so a path holding " ! " or spaces stays one token.
[[nodiscard]] KATAGLYPHIS_CPP_API auto quote_pipeline_value(const std::string &value) -> std::string;

[[nodiscard]] KATAGLYPHIS_CPP_API auto inference_pipeline_description(const std::string &input_source,
  const std::string &model_path,
  const std::string &output_format = "RAW") -> std::string;

[[nodiscard]] KATAGLYPHIS_CPP_API auto video_inference_pipeline_description(const std::string &video_source,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  const std::string &output_sink = "appsink") -> std::string;

[[nodiscard]] KATAGLYPHIS_CPP_API auto camera_inference_pipeline_description(const std::string &device,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::string;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_video_inference_pipeline(const std::string &video_source,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  const std::string &output_sink = "appsink") -> std::expected<GStreamerPipeline, GStreamerError>;

[[nodiscard]] KATAGLYPHIS_CPP_API auto create_camera_inference_pipeline(const std::string &device,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<GStreamerPipeline, GStreamerError>;

}// namespace kataglyphis::gstreamer
