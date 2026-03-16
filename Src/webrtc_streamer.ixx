module;

#include "kataglyphis_export.h"
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

export module kataglyphis.webrtc_streamer;

export import kataglyphis.config_loader;

export namespace kataglyphis::webrtc {

enum class WebRTCError {
    InitializationFailed,
    SignallingConnectionFailed,
    PipelineCreationFailed,
    NegotiationFailed,
    MediaError,
    LibcameraNotAvailable,
    EncoderNotAvailable,
    StateChangeFailed,
    InvalidConfiguration,
    Timeout
};

enum class VideoSource {
    Libcamera,      // Raspberry Pi camera via libcamera
    V4L2,           // USB camera via v4l2src
    TestPattern     // videotestsrc for testing
};

enum class VideoEncoder {
    H264_Software,  // x264enc
    H264_Hardware,  // v4l2h264enc (Pi hardware encoder)
    VP8,            // vp8enc
    VP9             // vp9enc
};

struct StreamConfig {
    VideoSource source{ VideoSource::Libcamera };
    VideoEncoder encoder{ VideoEncoder::H264_Hardware };
    
    std::string signalling_server_uri{ "ws://himbeere2:8443" };
    std::string peer_id;                 // Target peer ID (empty = produce stream)
    std::string producer_id;             // Our producer ID for the stream
    
    // Video settings
    std::uint32_t width{ 1280 };
    std::uint32_t height{ 720 };
    std::uint32_t framerate{ 30 };
    std::uint32_t bitrate_kbps{ 2000 };
    
    // Libcamera specific
    std::string camera_id;               // Empty = auto-detect first camera
    
    // V4L2 specific
    std::string v4l2_device{ "/dev/video0" };
    
    // Enable STUN/TURN
    std::vector<std::string> stun_servers;
    std::vector<std::string> turn_servers;
};

enum class StreamState {
    Idle,
    Connecting,
    Negotiating,
    Streaming,
    Paused,
    Error,
    Disconnected
};

using StateCallback = std::function<void(StreamState old_state, StreamState new_state)>;
using ErrorCallback = std::function<void(WebRTCError error, const std::string& message)>;

class KATAGLYPHIS_CPP_API WebRTCStreamer {
  public:
    WebRTCStreamer();
    ~WebRTCStreamer();

    WebRTCStreamer(const WebRTCStreamer&) = delete;
    WebRTCStreamer& operator=(const WebRTCStreamer&) = delete;
    WebRTCStreamer(WebRTCStreamer&&) noexcept;
    WebRTCStreamer& operator=(WebRTCStreamer&&) noexcept;

    // Initialize GStreamer (call once before creating streamers)
    [[nodiscard]] static auto initialize(int* argc = nullptr, char*** argv = nullptr)
        -> std::expected<void, WebRTCError>;
    
    static auto deinitialize() -> void;

    // Configure and start streaming
    [[nodiscard]] auto configure(const StreamConfig& config) -> std::expected<void, WebRTCError>;
    
    [[nodiscard]] auto start() -> std::expected<void, WebRTCError>;
    [[nodiscard]] auto stop() -> std::expected<void, WebRTCError>;
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
[[nodiscard]] auto create_libcamera_webrtc_stream(
    const std::string& signalling_server,
    std::uint32_t width = 1280,
    std::uint32_t height = 720,
    std::uint32_t fps = 30
) -> std::expected<WebRTCStreamer, WebRTCError>;

// Factory for V4L2 camera source
[[nodiscard]] auto create_v4l2_webrtc_stream(
    const std::string& signalling_server,
    const std::string& device = "/dev/video0",
    std::uint32_t width = 1280,
    std::uint32_t height = 720,
    std::uint32_t fps = 30
) -> std::expected<WebRTCStreamer, WebRTCError>;

// Factory for test pattern (useful for debugging)
[[nodiscard]] auto create_test_webrtc_stream(
    const std::string& signalling_server
) -> std::expected<WebRTCStreamer, WebRTCError>;

// Create StreamConfig from WebRTCConfig (loaded from JSON)
[[nodiscard]] KATAGLYPHIS_CPP_API auto create_stream_config_from_webrtc_config(
    const config::WebRTCConfig& webrtc_config,
    VideoSource source = VideoSource::Libcamera,
    VideoEncoder encoder = VideoEncoder::H264_Hardware
) -> StreamConfig;

// Load config from JSON file and create a configured WebRTCStreamer
[[nodiscard]] auto create_webrtc_stream_from_config(
    const std::filesystem::path& config_path,
    VideoSource source = VideoSource::Libcamera,
    VideoEncoder encoder = VideoEncoder::H264_Hardware
) -> std::expected<WebRTCStreamer, WebRTCError>;

} // namespace kataglyphis::webrtc
