module;

#include <expected>
#include <filesystem>
#include <fstream>
#include <string>
#include <sstream>

module kataglyphis.config_loader;

import nlohmann.json;

namespace kataglyphis::config {

using json = nlohmann::json;

namespace {

auto assign_optional_string(const json &object, const char *key, std::string &target)
  -> std::expected<void, ConfigError>
{
    const auto it = object.find(key);
    if (it == object.end()) { return {}; }
    if (!it->is_string()) { return std::unexpected(ConfigError::InvalidValue); }

    target = it->template get<std::string>();
    return {};
}

auto assign_optional_uint(const json &object, const char *key, std::uint32_t &target)
  -> std::expected<void, ConfigError>
{
    const auto it = object.find(key);
    if (it == object.end()) { return {}; }
    if (!it->is_number_unsigned()) { return std::unexpected(ConfigError::InvalidValue); }

    target = it->template get<std::uint32_t>();
    return {};
}

auto assign_optional_string_array(const json &object, const char *key, std::vector<std::string> &target)
  -> std::expected<void, ConfigError>
{
    const auto it = object.find(key);
    if (it == object.end()) { return {}; }
    if (!it->is_array()) { return std::unexpected(ConfigError::InvalidValue); }

    target.clear();
    target.reserve(it->size());
    for (const auto &value : *it) {
        if (!value.is_string()) { return std::unexpected(ConfigError::InvalidValue); }
        target.push_back(value.template get<std::string>());
    }

    return {};
}

template <typename Parser>
auto parse_optional_object(const json &object, const char *key, Parser &&parser) -> std::expected<void, ConfigError>
{
    const auto it = object.find(key);
    if (it == object.end()) { return {}; }
    if (!it->is_object()) { return std::unexpected(ConfigError::InvalidValue); }

    return parser(*it);
}

}  // namespace

auto get_default_webrtc_config() -> WebRTCConfig
{
    WebRTCConfig config;
    config.stun_servers.emplace_back("stun:stun.l.google.com:19302");
    return config;
}

auto parse_webrtc_config(const std::string &json_content) -> std::expected<WebRTCConfig, ConfigError>
{
    auto j = json::parse(json_content, nullptr, false);
    if (j.is_discarded()) { return std::unexpected(ConfigError::ParseError); }

    WebRTCConfig config;
    if (auto result = assign_optional_string(j, "signalingServerUrl", config.signaling_server_url); !result) {
        return std::unexpected(result.error());
    }
    if (auto result = assign_optional_uint(j, "reconnectionTimeoutMs", config.reconnection_timeout_ms); !result) {
        return std::unexpected(result.error());
    }
    if (auto result = assign_optional_string_array(j, "stunServers", config.stun_servers); !result) {
        return std::unexpected(result.error());
    }
    if (auto result = assign_optional_string_array(j, "turnServers", config.turn_servers); !result) {
        return std::unexpected(result.error());
    }

    if (auto result = parse_optional_object(j, "video", [&](const json &video) -> std::expected<void, ConfigError> {
            if (auto value = assign_optional_uint(video, "defaultWidth", config.video.default_width); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_uint(video, "defaultHeight", config.video.default_height); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_uint(video, "defaultFramerate", config.video.default_framerate); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_uint(video, "defaultBitrateKbps", config.video.default_bitrate_kbps);
                !value) {
                return std::unexpected(value.error());
            }
            return {};
        });
        !result) {
        return std::unexpected(result.error());
    }

    if (auto result = parse_optional_object(j, "texture", [&](const json &texture) -> std::expected<void, ConfigError> {
            if (auto value = assign_optional_uint(texture, "width", config.texture.width); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_uint(texture, "height", config.texture.height); !value) {
                return std::unexpected(value.error());
            }
            return {};
        });
        !result) {
        return std::unexpected(result.error());
    }

    if (auto result = parse_optional_object(j, "android", [&](const json &android) -> std::expected<void, ConfigError> {
            if (auto value = assign_optional_uint(android, "width", config.android.width); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_uint(android, "height", config.android.height); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_uint(android, "fps", config.android.fps); !value) {
                return std::unexpected(value.error());
            }
            return {};
        });
        !result) {
        return std::unexpected(result.error());
    }

    if (auto result = parse_optional_object(j, "stream", [&](const json &stream) -> std::expected<void, ConfigError> {
            if (auto value = assign_optional_string(stream, "source", config.stream.source); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "encoder", config.stream.encoder); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "device", config.stream.device); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "cameraId", config.stream.camera_id); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "inputPath", config.stream.input_path); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "inputUri", config.stream.input_uri); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "peerId", config.stream.peer_id); !value) {
                return std::unexpected(value.error());
            }
            if (auto value = assign_optional_string(stream, "producerId", config.stream.producer_id); !value) {
                return std::unexpected(value.error());
            }
            return {};
        });
        !result) {
        return std::unexpected(result.error());
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
