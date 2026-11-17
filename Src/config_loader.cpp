module;

#include <expected>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <limits>
#include <sstream>
#include <string>

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
        // get<std::uint32_t>() would wrap a larger value silently.
        if (!it->is_number_unsigned()
            || it->template get<std::uint64_t>() > std::numeric_limits<std::uint32_t>::max()) {
            return std::unexpected(ConfigError::InvalidValue);
        }

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

    template<typename Parser>
    auto parse_optional_object(const json &object, const char *key, Parser &&parser) -> std::expected<void, ConfigError>
    {
        const auto it = object.find(key);
        if (it == object.end()) { return {}; }
        if (!it->is_object()) { return std::unexpected(ConfigError::InvalidValue); }

        return parser(*it);
    }

    // The first failure in field order; every field is read, which only a valid file keeps.
    auto first_error(std::initializer_list<std::expected<void, ConfigError>> results)
      -> std::expected<void, ConfigError>
    {
        for (const auto &result : results) {
            if (!result) { return std::unexpected(result.error()); }
        }
        return {};
    }

}// namespace

auto get_default_webrtc_config() -> WebRTCConfig
{
    WebRTCConfig config;
    // The form webrtcsink parses, as the streamer's own fallback writes it.
    config.stun_servers.emplace_back("stun://stun.l.google.com:19302");
    return config;
}

auto parse_webrtc_config(const std::string &json_content) -> std::expected<WebRTCConfig, ConfigError>
{
    auto j = json::parse(json_content, nullptr, false);
    if (j.is_discarded()) { return std::unexpected(ConfigError::ParseError); }
    // Valid JSON that is not an object has none of the keys, and would otherwise pass as all defaults.
    if (!j.is_object()) { return std::unexpected(ConfigError::InvalidValue); }

    WebRTCConfig config;
    const auto read = first_error({
      assign_optional_string(j, "signalingServerUrl", config.signaling_server_url),
      assign_optional_string_array(j, "stunServers", config.stun_servers),
      assign_optional_string_array(j, "turnServers", config.turn_servers),
      parse_optional_object(j,
        "video",
        [&](const json &video) -> std::expected<void, ConfigError> {
            return first_error({
              assign_optional_uint(video, "defaultWidth", config.video.default_width),
              assign_optional_uint(video, "defaultHeight", config.video.default_height),
              assign_optional_uint(video, "defaultFramerate", config.video.default_framerate),
              assign_optional_uint(video, "defaultBitrateKbps", config.video.default_bitrate_kbps),
            });
        }),
      parse_optional_object(j,
        "texture",
        [&](const json &texture) -> std::expected<void, ConfigError> {
            return first_error({
              assign_optional_uint(texture, "width", config.texture.width),
              assign_optional_uint(texture, "height", config.texture.height),
            });
        }),
      parse_optional_object(j,
        "android",
        [&](const json &android) -> std::expected<void, ConfigError> {
            return first_error({
              assign_optional_uint(android, "width", config.android.width),
              assign_optional_uint(android, "height", config.android.height),
              assign_optional_uint(android, "fps", config.android.fps),
            });
        }),
      parse_optional_object(j,
        "stream",
        [&](const json &stream) -> std::expected<void, ConfigError> {
            return first_error({
              assign_optional_string(stream, "source", config.stream.source),
              assign_optional_string(stream, "encoder", config.stream.encoder),
              assign_optional_string(stream, "device", config.stream.device),
              assign_optional_string(stream, "cameraId", config.stream.camera_id),
              assign_optional_string(stream, "inputPath", config.stream.input_path),
              assign_optional_string(stream, "inputUri", config.stream.input_uri),
              assign_optional_string(stream, "producerId", config.stream.producer_id),
            });
        }),
    });
    if (!read) { return std::unexpected(read.error()); }

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
