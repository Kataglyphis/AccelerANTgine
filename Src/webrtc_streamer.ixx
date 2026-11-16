module;

#include "kataglyphis_export.h"
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

export module kataglyphis.webrtc_streamer;

export import kataglyphis.config_loader;

export namespace kataglyphis::webrtc {

enum class ConfigOverrideMode { UseConfig, Override };

// Numbered by hand: the CLI prints errors as integers, and the values nothing returned left their numbers free.
enum class WebRTCError {
    InitializationFailed = 0,
    PipelineCreationFailed = 2,
    MediaError = 4,
    StateChangeFailed = 7,
    InvalidConfiguration = 8,
};

// The value's own name, for a log line, a message or a binding; no default, so a new value fails the build here.
[[nodiscard]] constexpr auto to_string(WebRTCError error) noexcept -> std::string_view
{
    switch (error) {
    case WebRTCError::InitializationFailed:
        return "InitializationFailed";
    case WebRTCError::PipelineCreationFailed:
        return "PipelineCreationFailed";
    case WebRTCError::MediaError:
        return "MediaError";
    case WebRTCError::StateChangeFailed:
        return "StateChangeFailed";
    case WebRTCError::InvalidConfiguration:
        return "InvalidConfiguration";
    }
    return "UnknownError";
}

enum class VideoSource {
    Libcamera,// Raspberry Pi camera via libcamera
    V4L2,// USB camera via v4l2src
    TestPattern,// videotestsrc for testing
    File,// Local media file via uridecodebin
    Uri// Arbitrary URI via uridecodebin
};

enum class VideoEncoder {
    // webrtcsink picks the H.264 encoder by rank, a hardware one where the host has it.
    H264,
    VP8,// vp8enc
    VP9// vp9enc
};

struct StreamConfig
{
    VideoSource source{ VideoSource::Libcamera };
    VideoEncoder encoder{ VideoEncoder::H264 };

    std::string signalling_server_uri{ "ws://127.0.0.1:8443" };
    // The name consumers see in the producer list; empty generates one.
    std::string producer_id;

    // Video settings; bitrate_kbps is webrtcsink's start bitrate, which its congestion control moves from.
    std::uint32_t width{ 1280 };
    std::uint32_t height{ 720 };
    std::uint32_t framerate{ 30 };
    std::uint32_t bitrate_kbps{ 2000 };

    // Libcamera specific
    std::string camera_id;// Empty = auto-detect first camera

    // V4L2 specific
    std::string v4l2_device{ "/dev/video0" };

    // File/URI specific
    std::string input_path;
    std::string input_uri;

    // Enable STUN/TURN
    std::vector<std::string> stun_servers;
    std::vector<std::string> turn_servers;
};

// The webrtcsink STUN server when the config names none.
inline constexpr std::string_view kDefaultStunServer = "stun://stun.l.google.com:19302";

// The gst-launch text a WebRTCStreamer runs for `config`: the source, conversion and webrtcsink with every setting.
[[nodiscard]] KATAGLYPHIS_CPP_API auto webrtc_pipeline_description(const StreamConfig &config) -> std::string;

enum class StreamState { Idle, Connecting, Negotiating, Streaming, Paused, Error, Disconnected };

using StateCallback = std::function<void(StreamState old_state, StreamState new_state)>;
using ErrorCallback = std::function<void(WebRTCError error, const std::string &message)>;

// One element a pipeline here uses, and the plugin file GStreamer loads it from.
struct ElementLocation
{
    std::string element;
    bool found{ false };
    std::string plugin_file;
};

class KATAGLYPHIS_CPP_API WebRTCStreamer
{
  public:
    WebRTCStreamer();
    ~WebRTCStreamer();

    WebRTCStreamer(const WebRTCStreamer &) = delete;
    auto operator=(const WebRTCStreamer &) -> WebRTCStreamer & = delete;
    WebRTCStreamer(WebRTCStreamer && /*other*/) noexcept;
    auto operator=(WebRTCStreamer && /*other*/) noexcept -> WebRTCStreamer &;

    // Initialize GStreamer (call once before creating streamers)
    [[nodiscard]] static auto initialize(int *argc = nullptr, char ***argv = nullptr)
      -> std::expected<void, WebRTCError>;

    static auto deinitialize() -> void;

    // Every element the pipelines here use; call after initialize().
    [[nodiscard]] static auto locate_elements() -> std::vector<ElementLocation>;

    // True when initialize() saw GStreamer give up on its plugin scanner and scan in process.
    [[nodiscard]] static auto plugin_scanner_failed() -> bool;

    // The plugin directory a Linux package carries; empty anywhere else.
    [[nodiscard]] static auto bundled_plugin_dir() -> std::string;

    // Configure and start streaming
    [[nodiscard]] auto configure(const StreamConfig &config) -> std::expected<void, WebRTCError>;

    [[nodiscard]] auto start() -> std::expected<void, WebRTCError>;
    // Refused from inside a state or error callback, which run on the loop thread it joins: call request_stop() there.
    [[nodiscard]] auto stop() -> std::expected<void, WebRTCError>;
    // Safe from any thread, a callback included: sends the end of stream, after which the state turns Disconnected.
    auto request_stop() -> void;
    [[nodiscard]] auto pause() -> std::expected<void, WebRTCError>;
    [[nodiscard]] auto resume() -> std::expected<void, WebRTCError>;

    // State inspection
    [[nodiscard]] auto get_state() const -> StreamState;
    [[nodiscard]] auto is_streaming() const -> bool;
    [[nodiscard]] auto get_producer_id() const -> std::string;

    // Event callbacks
    auto set_state_callback(StateCallback callback) -> void;
    auto set_error_callback(ErrorCallback callback) -> void;

    // Dynamic settings (can be changed while streaming)
    [[nodiscard]] auto set_bitrate(std::uint32_t bitrate_kbps) -> std::expected<void, WebRTCError>;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Factory function for easy creation
[[nodiscard]] KATAGLYPHIS_CPP_API auto create_libcamera_webrtc_stream(const std::string &signalling_server,
  std::uint32_t width = 1280,
  std::uint32_t height = 720,
  std::uint32_t fps = 30) -> std::expected<WebRTCStreamer, WebRTCError>;

// Factory for V4L2 camera source
[[nodiscard]] KATAGLYPHIS_CPP_API auto create_v4l2_webrtc_stream(const std::string &signalling_server,
  const std::string &device = "/dev/video0",
  std::uint32_t width = 1280,
  std::uint32_t height = 720,
  std::uint32_t fps = 30) -> std::expected<WebRTCStreamer, WebRTCError>;

// Factory for test pattern (useful for debugging)
[[nodiscard]] KATAGLYPHIS_CPP_API auto create_test_webrtc_stream(const std::string &signalling_server)
  -> std::expected<WebRTCStreamer, WebRTCError>;

// Create StreamConfig from WebRTCConfig (loaded from JSON)
[[nodiscard]] KATAGLYPHIS_CPP_API auto create_stream_config_from_webrtc_config(
  const config::WebRTCConfig &webrtc_config,
  VideoSource source = VideoSource::Libcamera,
  VideoEncoder encoder = VideoEncoder::H264,
  ConfigOverrideMode source_override_mode = ConfigOverrideMode::UseConfig,
  ConfigOverrideMode encoder_override_mode = ConfigOverrideMode::UseConfig) -> StreamConfig;

// Load config from JSON file and create a configured WebRTCStreamer
[[nodiscard]] KATAGLYPHIS_CPP_API auto create_webrtc_stream_from_config(const std::filesystem::path &config_path,
  VideoSource source = VideoSource::Libcamera,
  VideoEncoder encoder = VideoEncoder::H264,
  ConfigOverrideMode source_override_mode = ConfigOverrideMode::UseConfig,
  ConfigOverrideMode encoder_override_mode = ConfigOverrideMode::UseConfig)
  -> std::expected<WebRTCStreamer, WebRTCError>;

}// namespace kataglyphis::webrtc
