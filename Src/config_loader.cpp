module;

#include <fstream>
#include <nlohmann/json.hpp>
#include <sstream>

module kataglyphis.config_loader;

namespace kataglyphis::config {

using json = nlohmann::json;

auto get_default_webrtc_config() -> WebRTCConfig {
    WebRTCConfig config;
    config.stun_servers.push_back("stun:stun.l.google.com:19302");
    return config;
}

auto parse_webrtc_config(const std::string& json_content)
    -> std::expected<WebRTCConfig, ConfigError> {
    try {
        auto j = json::parse(json_content);
        WebRTCConfig config;

        // Parse signaling server URL
        if (j.contains("signalingServerUrl")) {
            config.signaling_server_url = j["signalingServerUrl"].get<std::string>();
        }

        // Parse reconnection timeout
        if (j.contains("reconnectionTimeoutMs")) {
            config.reconnection_timeout_ms = j["reconnectionTimeoutMs"].get<std::uint32_t>();
        }

        // Parse STUN servers
        if (j.contains("stunServers") && j["stunServers"].is_array()) {
            for (const auto& server : j["stunServers"]) {
                config.stun_servers.push_back(server.get<std::string>());
            }
        }

        // Parse TURN servers
        if (j.contains("turnServers") && j["turnServers"].is_array()) {
            for (const auto& server : j["turnServers"]) {
                config.turn_servers.push_back(server.get<std::string>());
            }
        }

        // Parse video settings
        if (j.contains("video") && j["video"].is_object()) {
            const auto& video = j["video"];
            if (video.contains("defaultWidth")) {
                config.video.default_width = video["defaultWidth"].get<std::uint32_t>();
            }
            if (video.contains("defaultHeight")) {
                config.video.default_height = video["defaultHeight"].get<std::uint32_t>();
            }
            if (video.contains("defaultFramerate")) {
                config.video.default_framerate = video["defaultFramerate"].get<std::uint32_t>();
            }
            if (video.contains("defaultBitrateKbps")) {
                config.video.default_bitrate_kbps = video["defaultBitrateKbps"].get<std::uint32_t>();
            }
        }

        // Parse texture settings
        if (j.contains("texture") && j["texture"].is_object()) {
            const auto& texture = j["texture"];
            if (texture.contains("width")) {
                config.texture.width = texture["width"].get<std::uint32_t>();
            }
            if (texture.contains("height")) {
                config.texture.height = texture["height"].get<std::uint32_t>();
            }
        }

        // Parse Android settings
        if (j.contains("android") && j["android"].is_object()) {
            const auto& android = j["android"];
            if (android.contains("width")) {
                config.android.width = android["width"].get<std::uint32_t>();
            }
            if (android.contains("height")) {
                config.android.height = android["height"].get<std::uint32_t>();
            }
            if (android.contains("fps")) {
                config.android.fps = android["fps"].get<std::uint32_t>();
            }
        }

        return config;

    } catch (const json::parse_error&) {
        return std::unexpected(ConfigError::ParseError);
    } catch (const json::type_error&) {
        return std::unexpected(ConfigError::InvalidValue);
    }
}

auto load_webrtc_config(const std::filesystem::path& config_path)
    -> std::expected<WebRTCConfig, ConfigError> {
    
    if (!std::filesystem::exists(config_path)) {
        return std::unexpected(ConfigError::FileNotFound);
    }

    std::ifstream file(config_path);
    if (!file.is_open()) {
        return std::unexpected(ConfigError::FileNotFound);
    }

    std::stringstream buffer;
    buffer << file.rdbuf();
    
    return parse_webrtc_config(buffer.str());
}

} // namespace kataglyphis::config
