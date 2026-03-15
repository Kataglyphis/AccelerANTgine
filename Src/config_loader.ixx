module;

#include "kataglyphis_export.h"
#include <cstdint>
#include <expected>
#include <filesystem>
#include <string>
#include <vector>

export module kataglyphis.config_loader;

export namespace kataglyphis::config {

enum class ConfigError {
    FileNotFound,
    ParseError,
    MissingField,
    InvalidValue
};

/// Video settings from webrtc_settings.json
struct VideoConfig {
    std::uint32_t default_width{ 1280 };
    std::uint32_t default_height{ 720 };
    std::uint32_t default_framerate{ 30 };
    std::uint32_t default_bitrate_kbps{ 2000 };
};

/// Native texture settings
struct TextureConfig {
    std::uint32_t width{ 640 };
    std::uint32_t height{ 480 };
};

/// Android-specific settings
struct AndroidConfig {
    std::uint32_t width{ 320 };
    std::uint32_t height{ 240 };
    std::uint32_t fps{ 15 };
};

/// Complete WebRTC configuration loaded from JSON
struct WebRTCConfig {
    std::string signaling_server_url{ "ws://127.0.0.1:8443" };
    std::uint32_t reconnection_timeout_ms{ 5000 };
    std::vector<std::string> stun_servers;
    std::vector<std::string> turn_servers;
    VideoConfig video;
    TextureConfig texture;
    AndroidConfig android;
};

/// Load WebRTC configuration from a JSON file
/// @param config_path Path to webrtc_settings.json
/// @return WebRTCConfig on success, ConfigError on failure
[[nodiscard]] KATAGLYPHIS_CPP_API auto load_webrtc_config(
    const std::filesystem::path& config_path
) -> std::expected<WebRTCConfig, ConfigError>;

/// Load WebRTC configuration from a JSON string
/// @param json_content JSON string content
/// @return WebRTCConfig on success, ConfigError on failure
[[nodiscard]] KATAGLYPHIS_CPP_API auto parse_webrtc_config(
    const std::string& json_content
) -> std::expected<WebRTCConfig, ConfigError>;

/// Get default configuration (used when no config file is found)
[[nodiscard]] KATAGLYPHIS_CPP_API auto get_default_webrtc_config() -> WebRTCConfig;

} // namespace kataglyphis::config
