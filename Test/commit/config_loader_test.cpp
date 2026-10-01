#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <string>
#include <string_view>
#include <vector>

import kataglyphis.config_loader;

namespace cfg = kataglyphis::config;
using kataglyphis::test::TempFile;

namespace {

constexpr std::string_view kFullSettings = R"({
  "signalingServerUrl": "wss://example.test/webrtc-ws",
  "reconnectionTimeoutMs": 2500,
  "stunServers": ["stun:one.example:3478", "stun:two.example:3478"],
  "turnServers": ["turn:relay.example:3478"],
  "video": { "defaultWidth": 1920, "defaultHeight": 1080, "defaultFramerate": 60, "defaultBitrateKbps": 8000 },
  "texture": { "width": 800, "height": 600 },
  "android": { "width": 640, "height": 360, "fps": 24 },
  "stream": {
    "source": "v4l2",
    "encoder": "vp8",
    "device": "/dev/video4",
    "cameraId": "imx708",
    "inputPath": "/tmp/clip.mp4",
    "inputUri": "rtsp://camera.example/stream",
    "peerId": "peer-1",
    "producerId": "producer-7"
  }
})";

auto parse(std::string_view json) { return cfg::parse_webrtc_config(std::string(json)); }

}// namespace

TEST(WebRtcConfig, DefaultsPointAtALocalSignallingServer)
{
    const auto config = cfg::get_default_webrtc_config();
    EXPECT_EQ(config.signaling_server_url, "ws://127.0.0.1:8443");
    EXPECT_EQ(config.reconnection_timeout_ms, 5000U);
    EXPECT_EQ(config.stun_servers, (std::vector<std::string>{ "stun:stun.l.google.com:19302" }));
    EXPECT_TRUE(config.turn_servers.empty());
    EXPECT_EQ(config.video.default_width, 1280U);
    EXPECT_EQ(config.video.default_height, 720U);
    EXPECT_EQ(config.video.default_framerate, 30U);
    EXPECT_EQ(config.video.default_bitrate_kbps, 2000U);
    EXPECT_EQ(config.texture.width, 640U);
    EXPECT_EQ(config.texture.height, 480U);
    EXPECT_EQ(config.android.width, 320U);
    EXPECT_EQ(config.android.height, 240U);
    EXPECT_EQ(config.android.fps, 15U);
    EXPECT_EQ(config.stream.source, "libcamera");
    EXPECT_EQ(config.stream.encoder, "h264-hw");
    EXPECT_EQ(config.stream.device, "/dev/video0");
    EXPECT_TRUE(config.stream.camera_id.empty());
    EXPECT_TRUE(config.stream.producer_id.empty());
}

TEST(WebRtcConfig, EmptyObjectKeepsTheStructDefaultsWithoutStun)
{
    const auto config = parse("{}");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->signaling_server_url, "ws://127.0.0.1:8443");
    EXPECT_EQ(config->video.default_width, 1280U);
    // Unlike get_default_webrtc_config(), parsing starts from no STUN server.
    EXPECT_TRUE(config->stun_servers.empty());
}

TEST(WebRtcConfig, ParsesEveryField)
{
    const auto config = parse(kFullSettings);
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->signaling_server_url, "wss://example.test/webrtc-ws");
    EXPECT_EQ(config->reconnection_timeout_ms, 2500U);
    EXPECT_EQ(config->stun_servers, (std::vector<std::string>{ "stun:one.example:3478", "stun:two.example:3478" }));
    EXPECT_EQ(config->turn_servers, (std::vector<std::string>{ "turn:relay.example:3478" }));
    EXPECT_EQ(config->video.default_width, 1920U);
    EXPECT_EQ(config->video.default_height, 1080U);
    EXPECT_EQ(config->video.default_framerate, 60U);
    EXPECT_EQ(config->video.default_bitrate_kbps, 8000U);
    EXPECT_EQ(config->texture.width, 800U);
    EXPECT_EQ(config->texture.height, 600U);
    EXPECT_EQ(config->android.width, 640U);
    EXPECT_EQ(config->android.height, 360U);
    EXPECT_EQ(config->android.fps, 24U);
    EXPECT_EQ(config->stream.source, "v4l2");
    EXPECT_EQ(config->stream.encoder, "vp8");
    EXPECT_EQ(config->stream.device, "/dev/video4");
    EXPECT_EQ(config->stream.camera_id, "imx708");
    EXPECT_EQ(config->stream.input_path, "/tmp/clip.mp4");
    EXPECT_EQ(config->stream.input_uri, "rtsp://camera.example/stream");
    EXPECT_EQ(config->stream.peer_id, "peer-1");
    EXPECT_EQ(config->stream.producer_id, "producer-7");
}

TEST(WebRtcConfig, PartialSectionsOnlyOverrideWhatTheyName)
{
    const auto config = parse(R"({"video": {"defaultFramerate": 15}, "stream": {"source": "test"}})");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->video.default_framerate, 15U);
    EXPECT_EQ(config->video.default_width, 1280U);
    EXPECT_EQ(config->stream.source, "test");
    EXPECT_EQ(config->stream.encoder, "h264-hw");
}

TEST(WebRtcConfig, UnknownKeysAreIgnored)
{
    const auto config = parse(R"({"futureKey": [1, 2], "video": {"hdr": true}, "texture": {"width": 320}})");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->texture.width, 320U);
}

TEST(WebRtcConfig, MalformedJsonIsAParseError)
{
    for (const std::string_view json : { "", "{", R"({"video": })", "{} trailing", R"({"a": "\x"})", "{'a': 1}" }) {
        const auto config = parse(json);
        ASSERT_FALSE(config.has_value()) << json;
        EXPECT_EQ(config.error(), cfg::ConfigError::ParseError) << json;
    }
}

TEST(WebRtcConfig, ANonObjectRootIsInvalid)
{
    for (const std::string_view json : { "[]", "42", R"("ws://127.0.0.1:8443")", "null", "true" }) {
        const auto config = parse(json);
        ASSERT_FALSE(config.has_value()) << json;
        EXPECT_EQ(config.error(), cfg::ConfigError::InvalidValue) << json;
    }
}

TEST(WebRtcConfig, WrongTypesAreInvalid)
{
    for (const std::string_view json : { R"({"signalingServerUrl": 8443})",
           R"({"reconnectionTimeoutMs": "5000"})",
           R"({"stunServers": "stun:one"})",
           R"({"stunServers": ["stun:one", 2]})",
           R"({"turnServers": [null]})",
           R"({"video": []})",
           R"({"video": {"defaultWidth": true}})",
           R"({"texture": "640x480"})",
           R"({"android": {"fps": [15]}})",
           R"({"stream": {"device": {}}})",
           R"({"stream": {"producerId": 7}})" }) {
        const auto config = parse(json);
        ASSERT_FALSE(config.has_value()) << json;
        EXPECT_EQ(config.error(), cfg::ConfigError::InvalidValue) << json;
    }
}

TEST(WebRtcConfig, NumbersMustBeUnsigned32BitIntegers)
{
    for (const std::string_view json : { R"({"texture": {"width": -1}})",
           R"({"texture": {"width": 1.5}})",
           R"({"texture": {"width": 1e3}})",
           R"({"texture": {"width": 4294967296}})",
           R"({"reconnectionTimeoutMs": 18446744073709551615})" }) {
        const auto config = parse(json);
        ASSERT_FALSE(config.has_value()) << json;
        EXPECT_EQ(config.error(), cfg::ConfigError::InvalidValue) << json;
    }

    const auto largest = parse(R"({"texture": {"width": 4294967295, "height": 0}})");
    ASSERT_TRUE(largest.has_value());
    EXPECT_EQ(largest->texture.width, 4294967295U);
    EXPECT_EQ(largest->texture.height, 0U);
}

TEST(WebRtcConfig, AnEmptyServerListReplacesTheList)
{
    const auto config = parse(R"({"stunServers": [], "turnServers": []})");
    ASSERT_TRUE(config.has_value());
    EXPECT_TRUE(config->stun_servers.empty());
    EXPECT_TRUE(config->turn_servers.empty());
}

TEST(WebRtcConfig, StringsKeepTheirUnicodeAndEscapes)
{
    const auto config =
      parse(R"({"stream": {"cameraId": "Kamera \u00fc \"front\"", "inputPath": "C:\\clips\\a.mp4"}})");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->stream.camera_id, "Kamera \xC3\xBC \"front\"");
    EXPECT_EQ(config->stream.input_path, "C:\\clips\\a.mp4");
}

TEST(WebRtcConfig, LoadsTheSameConfigFromAFile)
{
    const TempFile file("kataglyphis-webrtc", ".json", kFullSettings);
    const auto config = cfg::load_webrtc_config(file.path());
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->signaling_server_url, "wss://example.test/webrtc-ws");
    EXPECT_EQ(config->stream.producer_id, "producer-7");
}

TEST(WebRtcConfig, MissingFileIsFileNotFound)
{
    const auto config = cfg::load_webrtc_config(kataglyphis::test::missing_path("webrtc_settings.json"));
    ASSERT_FALSE(config.has_value());
    EXPECT_EQ(config.error(), cfg::ConfigError::FileNotFound);
}

TEST(WebRtcConfig, MalformedFileIsAParseError)
{
    const TempFile file("kataglyphis-webrtc-broken", ".json", "{\"video\": ");
    const auto config = cfg::load_webrtc_config(file.path());
    ASSERT_FALSE(config.has_value());
    EXPECT_EQ(config.error(), cfg::ConfigError::ParseError);
}
