module;

#include <expected>
#include <fstream>
#include <nlohmann/json.hpp>
#include <sstream>

module kataglyphis.config_loader;

namespace kataglyphis::config {

using json = nlohmann::json;

auto get_default_webrtc_config() -> WebRTCConfig
{
    WebRTCConfig config;
    config.stun_servers.push_back("stun:stun.l.google.com:19302");
    return config;
}

auto parse_webrtc_config(const std::string &json_content) -> std::expected<WebRTCConfig, ConfigError>
{
    if (!json::accept(json_content)) { return std::unexpected(ConfigError::ParseError); }

    auto j = json::parse(json_content);
    WebRTCConfig config;
    auto safe_get_string = [&j](const std::string &key) -> std::expected<std::string, ConfigError> {
        if (!j.contains(key) || !j[key].is_string()) { return std::unexpected(ConfigError::InvalidValue); }
        return j[key].template get<std::string>();
    };

    auto safe_get_uint = [](const auto &obj, const std::string &key) -> std::expected<std::uint32_t, ConfigError> {
        if (!obj.contains(key) || !obj[key].is_number_unsigned()) { return std::unexpected(ConfigError::InvalidValue); }
        return obj[key].template get<std::uint32_t>();
    };
    if (j.contains("signalingServerUrl")) {
        if (auto val = safe_get_string("signalingServerUrl")) {
            config.signaling_server_url = *val;
        } else {
            return std::unexpected(val.error());
        }
    }

    if (j.contains("reconnectionTimeoutMs")) {
        if (auto val = safe_get_uint(j, "reconnectionTimeoutMs")) {
            config.reconnection_timeout_ms = *val;
        } else {
            return std::unexpected(val.error());
        }
    }

    if (j.contains("stunServers") && j["stunServers"].is_array()) {
        for (const auto &server : j["stunServers"]) {
            if (!server.is_string()) { return std::unexpected(ConfigError::InvalidValue); }
            config.stun_servers.push_back(server.get<std::string>());
        }
    }

    if (j.contains("turnServers") && j["turnServers"].is_array()) {
        for (const auto &server : j["turnServers"]) {
            if (!server.is_string()) { return std::unexpected(ConfigError::InvalidValue); }
            config.turn_servers.push_back(server.get<std::string>());
        }
    }

    if (j.contains("video") && j["video"].is_object()) {
        const auto &video = j["video"];
        if (video.contains("defaultWidth")) {
            if (auto val = safe_get_uint(video, "defaultWidth")) {
                config.video.default_width = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
        if (video.contains("defaultHeight")) {
            if (auto val = safe_get_uint(video, "defaultHeight")) {
                config.video.default_height = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
        if (video.contains("defaultFramerate")) {
            if (auto val = safe_get_uint(video, "defaultFramerate")) {
                config.video.default_framerate = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
        if (video.contains("defaultBitrateKbps")) {
            if (auto val = safe_get_uint(video, "defaultBitrateKbps")) {
                config.video.default_bitrate_kbps = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
    }

    if (j.contains("texture") && j["texture"].is_object()) {
        const auto &texture = j["texture"];
        if (texture.contains("width")) {
            if (auto val = safe_get_uint(texture, "width")) {
                config.texture.width = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
        if (texture.contains("height")) {
            if (auto val = safe_get_uint(texture, "height")) {
                config.texture.height = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
    }

    if (j.contains("android") && j["android"].is_object()) {
        const auto &android = j["android"];
        if (android.contains("width")) {
            if (auto val = safe_get_uint(android, "width")) {
                config.android.width = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
        if (android.contains("height")) {
            if (auto val = safe_get_uint(android, "height")) {
                config.android.height = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
        if (android.contains("fps")) {
            if (auto val = safe_get_uint(android, "fps")) {
                config.android.fps = *val;
            } else {
                return std::unexpected(val.error());
            }
        }
    }

    return config;
}

auto load_webrtc_config(const std::filesystem::path &config_path) -> std::expected<WebRTCConfig, ConfigError>
{

    if (!std::filesystem::exists(config_path)) { return std::unexpected(ConfigError::FileNotFound); }

    std::ifstream file(config_path);
    if (!file.is_open()) { return std::unexpected(ConfigError::FileNotFound); }

    std::stringstream buffer;
    buffer << file.rdbuf();

    return parse_webrtc_config(buffer.str());
}

}// namespace kataglyphis::config
