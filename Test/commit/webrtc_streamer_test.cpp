#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <initializer_list>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

import kataglyphis.config_loader;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.webrtc_streamer;

#include "gstreamer_test_support.h"

namespace webrtc = kataglyphis::webrtc;
namespace cfg = kataglyphis::config;
using kataglyphis::test::TempFile;

namespace {

// Port 1 refuses the connection at once, so a started stream fails fast and deterministically.
constexpr std::string_view kRefusingServer = "ws://127.0.0.1:1";

auto test_pattern_config() -> webrtc::StreamConfig
{
    webrtc::StreamConfig config;
    config.source = webrtc::VideoSource::TestPattern;
    config.encoder = webrtc::VideoEncoder::VP8;
    config.signalling_server_uri = std::string(kRefusingServer);
    config.width = 64;
    config.height = 48;
    config.framerate = 15;
    return config;
}

}// namespace

// Skips where neither webrtcsink nor webrtcbin exists, which WebRTCStreamer::initialize() demands.
#define KATAGLYPHIS_REQUIRE_WEBRTC()                                              \
    do {                                                                          \
        if (!webrtc::WebRTCStreamer::initialize()) {                              \
            GTEST_SKIP() << "neither webrtcsink nor webrtcbin is installed here"; \
        }                                                                         \
    } while (false)

TEST(WebRtcStreamConfig, CopiesEveryFieldFromTheSettings)
{
    cfg::WebRTCConfig settings;
    settings.signaling_server_url = "wss://signal.example/ws";
    settings.video = { 1920, 1080, 60, 6000 };
    settings.stream.source = "v4l2";
    settings.stream.encoder = "vp9";
    settings.stream.device = "/dev/video3";
    settings.stream.camera_id = "imx219";
    settings.stream.input_path = "/clips/a.mp4";
    settings.stream.input_uri = "rtsp://cam/stream";
    settings.stream.peer_id = "peer";
    settings.stream.producer_id = "producer";
    settings.stun_servers = { "stun:a", "stun:b" };
    settings.turn_servers = { "turn:c" };

    const auto config = webrtc::create_stream_config_from_webrtc_config(settings);
    EXPECT_EQ(config.source, webrtc::VideoSource::V4L2);
    EXPECT_EQ(config.encoder, webrtc::VideoEncoder::VP9);
    EXPECT_EQ(config.signalling_server_uri, "wss://signal.example/ws");
    EXPECT_EQ(config.width, 1920U);
    EXPECT_EQ(config.height, 1080U);
    EXPECT_EQ(config.framerate, 60U);
    EXPECT_EQ(config.bitrate_kbps, 6000U);
    EXPECT_EQ(config.v4l2_device, "/dev/video3");
    EXPECT_EQ(config.camera_id, "imx219");
    EXPECT_EQ(config.input_path, "/clips/a.mp4");
    EXPECT_EQ(config.input_uri, "rtsp://cam/stream");
    EXPECT_EQ(config.peer_id, "peer");
    EXPECT_EQ(config.producer_id, "producer");
    EXPECT_EQ(config.stun_servers, (std::vector<std::string>{ "stun:a", "stun:b" }));
    EXPECT_EQ(config.turn_servers, (std::vector<std::string>{ "turn:c" }));
}

TEST(WebRtcStreamConfig, SourceNamesMapToTheirSources)
{
    const std::initializer_list<std::pair<std::string_view, webrtc::VideoSource>> names{
        { "libcamera", webrtc::VideoSource::Libcamera },
        { "v4l2", webrtc::VideoSource::V4L2 },
        { "test", webrtc::VideoSource::TestPattern },
        { "file", webrtc::VideoSource::File },
        { "uri", webrtc::VideoSource::Uri },
    };
    for (const auto &[name, source] : names) {
        cfg::WebRTCConfig settings;
        settings.stream.source = std::string(name);
        EXPECT_EQ(webrtc::create_stream_config_from_webrtc_config(settings, webrtc::VideoSource::File).source, source)
          << name;
    }
}

TEST(WebRtcStreamConfig, EncoderNamesMapToTheirEncoders)
{
    const std::initializer_list<std::pair<std::string_view, webrtc::VideoEncoder>> names{
        { "h264-hw", webrtc::VideoEncoder::H264_Hardware },
        { "h264-sw", webrtc::VideoEncoder::H264_Software },
        { "vp8", webrtc::VideoEncoder::VP8 },
        { "vp9", webrtc::VideoEncoder::VP9 },
    };
    for (const auto &[name, encoder] : names) {
        cfg::WebRTCConfig settings;
        settings.stream.encoder = std::string(name);
        const auto config = webrtc::create_stream_config_from_webrtc_config(
          settings, webrtc::VideoSource::Libcamera, webrtc::VideoEncoder::VP8);
        EXPECT_EQ(config.encoder, encoder) << name;
    }
}

TEST(WebRtcStreamConfig, UnknownNamesFallBackToTheArguments)
{
    cfg::WebRTCConfig settings;
    settings.stream.source = "webcam";
    settings.stream.encoder = "h265";
    const auto config = webrtc::create_stream_config_from_webrtc_config(
      settings, webrtc::VideoSource::TestPattern, webrtc::VideoEncoder::VP9);
    EXPECT_EQ(config.source, webrtc::VideoSource::TestPattern);
    EXPECT_EQ(config.encoder, webrtc::VideoEncoder::VP9);
}

TEST(WebRtcStreamConfig, OverrideModeIgnoresTheSettingsNames)
{
    cfg::WebRTCConfig settings;
    settings.stream.source = "v4l2";
    settings.stream.encoder = "vp9";
    const auto config = webrtc::create_stream_config_from_webrtc_config(settings,
      webrtc::VideoSource::Uri,
      webrtc::VideoEncoder::H264_Software,
      webrtc::ConfigOverrideMode::Override,
      webrtc::ConfigOverrideMode::Override);
    EXPECT_EQ(config.source, webrtc::VideoSource::Uri);
    EXPECT_EQ(config.encoder, webrtc::VideoEncoder::H264_Software);

    const auto mixed = webrtc::create_stream_config_from_webrtc_config(settings,
      webrtc::VideoSource::Uri,
      webrtc::VideoEncoder::H264_Software,
      webrtc::ConfigOverrideMode::UseConfig,
      webrtc::ConfigOverrideMode::Override);
    EXPECT_EQ(mixed.source, webrtc::VideoSource::V4L2);
    EXPECT_EQ(mixed.encoder, webrtc::VideoEncoder::H264_Software);
}

TEST(WebRtcStreamer, AnUnconfiguredStreamerRefusesToRun)
{
    webrtc::WebRTCStreamer streamer;
    EXPECT_EQ(streamer.get_state(), webrtc::StreamState::Idle);
    EXPECT_FALSE(streamer.is_streaming());
    EXPECT_TRUE(streamer.get_producer_id().empty());
    EXPECT_EQ(kataglyphis::test::error_of(streamer.start()), webrtc::WebRTCError::PipelineCreationFailed);
    EXPECT_EQ(kataglyphis::test::error_of(streamer.pause()), webrtc::WebRTCError::PipelineCreationFailed);
    EXPECT_EQ(kataglyphis::test::error_of(streamer.resume()), webrtc::WebRTCError::PipelineCreationFailed);
    EXPECT_TRUE(streamer.stop().has_value());
    EXPECT_TRUE(streamer.set_bitrate(4000).has_value());
}

TEST(WebRtcStreamer, ConfigureRejectsIncompleteSettings)
{
    KATAGLYPHIS_REQUIRE_WEBRTC();
    auto zero_width = test_pattern_config();
    zero_width.width = 0;
    auto zero_height = test_pattern_config();
    zero_height.height = 0;
    auto zero_rate = test_pattern_config();
    zero_rate.framerate = 0;
    auto no_server = test_pattern_config();
    no_server.signalling_server_uri.clear();
    auto v4l2_without_device = test_pattern_config();
    v4l2_without_device.source = webrtc::VideoSource::V4L2;
    v4l2_without_device.v4l2_device.clear();
    auto file_without_path = test_pattern_config();
    file_without_path.source = webrtc::VideoSource::File;
    auto uri_without_uri = test_pattern_config();
    uri_without_uri.source = webrtc::VideoSource::Uri;

    for (const auto &config :
      { zero_width, zero_height, zero_rate, no_server, v4l2_without_device, file_without_path, uri_without_uri }) {
        webrtc::WebRTCStreamer streamer;
        EXPECT_EQ(kataglyphis::test::error_of(streamer.configure(config)), webrtc::WebRTCError::InvalidConfiguration);
        EXPECT_EQ(kataglyphis::test::error_of(streamer.start()), webrtc::WebRTCError::PipelineCreationFailed);
    }
}

TEST(WebRtcStreamer, ConfiguresATestPatternStream)
{
    KATAGLYPHIS_REQUIRE_WEBRTC();
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "videoconvert", "webrtcsink");
    auto config = test_pattern_config();
    config.producer_id = "kataglyphis-test";
    webrtc::WebRTCStreamer streamer;
    ASSERT_TRUE(streamer.configure(config).has_value());
    EXPECT_EQ(streamer.get_producer_id(), "kataglyphis-test");
    EXPECT_EQ(streamer.get_state(), webrtc::StreamState::Idle);
    // Configuring again replaces the pipeline and keeps the streamer usable.
    config.producer_id.clear();
    config.encoder = webrtc::VideoEncoder::H264_Software;
    ASSERT_TRUE(streamer.configure(config).has_value());
    EXPECT_TRUE(streamer.get_producer_id().starts_with("stream-"));
    EXPECT_TRUE(streamer.stop().has_value());
}

TEST(WebRtcStreamer, ConfiguresAFileStream)
{
    KATAGLYPHIS_REQUIRE_WEBRTC();
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS(
      "uridecodebin", "queue", "videoconvert", "videoscale", "videorate", "webrtcsink");
    auto config = test_pattern_config();
    config.source = webrtc::VideoSource::File;
    // Configure builds the pipeline without opening the file, so a name with quotes and spaces is enough.
    config.input_path = "clips/a \"quoted\" name.mp4";
    webrtc::WebRTCStreamer streamer;
    EXPECT_TRUE(streamer.configure(config).has_value());
}

TEST(WebRtcStreamer, AStartWithoutASignallingServerEndsInError)
{
    KATAGLYPHIS_REQUIRE_WEBRTC();
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "videoconvert", "webrtcsink");
    webrtc::WebRTCStreamer streamer;

    std::mutex mutex;
    std::condition_variable changed;
    std::vector<webrtc::StreamState> states;
    std::optional<webrtc::WebRTCError> reported;
    streamer.set_state_callback([&](webrtc::StreamState, webrtc::StreamState next) {
        {
            std::scoped_lock lock(mutex);
            states.push_back(next);
        }
        changed.notify_all();
    });
    streamer.set_error_callback([&](webrtc::WebRTCError error, const std::string &) {
        {
            std::scoped_lock lock(mutex);
            reported = error;
        }
        changed.notify_all();
    });

    ASSERT_TRUE(streamer.configure(test_pattern_config()).has_value());
    const auto started = streamer.start();

    {
        std::unique_lock lock(mutex);
        // A PLAYING state change may still land after the error, so the history is checked, not the final state.
        const bool failed = changed.wait_for(lock, kataglyphis::test::kStreamTimeout, [&] {
            if (started.has_value()) { return reported.has_value(); }
            return std::ranges::find(states, webrtc::StreamState::Error) != states.end();
        });
        EXPECT_TRUE(failed);
        ASSERT_FALSE(states.empty());
        EXPECT_EQ(states.front(), webrtc::StreamState::Connecting);
        EXPECT_NE(std::ranges::find(states, webrtc::StreamState::Error), states.end());
        // A failure after start() returned comes through the bus, and so through the error callback.
        if (started.has_value()) { EXPECT_EQ(reported, webrtc::WebRTCError::MediaError); }
    }

    EXPECT_TRUE(streamer.stop().has_value());
    EXPECT_EQ(streamer.get_state(), webrtc::StreamState::Idle);
}

TEST(WebRtcStreamer, FactoriesConfigureTheirSources)
{
    KATAGLYPHIS_REQUIRE_WEBRTC();
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "videoconvert", "webrtcsink");
    const auto test_stream = webrtc::create_test_webrtc_stream(std::string(kRefusingServer));
    ASSERT_TRUE(test_stream.has_value());
    EXPECT_TRUE(test_stream->get_producer_id().starts_with("stream-"));
    EXPECT_EQ(test_stream->get_state(), webrtc::StreamState::Idle);

    EXPECT_EQ(kataglyphis::test::error_of(webrtc::create_v4l2_webrtc_stream("", "")),
      webrtc::WebRTCError::InvalidConfiguration);
    EXPECT_EQ(kataglyphis::test::error_of(webrtc::create_libcamera_webrtc_stream(std::string(kRefusingServer), 0)),
      webrtc::WebRTCError::InvalidConfiguration);

    if (kataglyphis::test::missing_gstreamer_element({ "v4l2src" }).empty()) {
        EXPECT_TRUE(
          webrtc::create_v4l2_webrtc_stream(std::string(kRefusingServer), "/dev/video0", 64, 48, 15).has_value());
    }
    if (!kataglyphis::test::missing_gstreamer_element({ "libcamerasrc" }).empty()) {
        EXPECT_EQ(
          kataglyphis::test::error_of(webrtc::create_libcamera_webrtc_stream(std::string(kRefusingServer), 64, 48, 15)),
          webrtc::WebRTCError::PipelineCreationFailed);
    }
}

TEST(WebRtcStreamer, AConfigFileDrivesTheFactory)
{
    KATAGLYPHIS_REQUIRE_WEBRTC();
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "videoconvert", "webrtcsink");
    const TempFile settings("kataglyphis-webrtc-stream",
      ".json",
      R"({"signalingServerUrl": "ws://127.0.0.1:1", "video": {"defaultWidth": 64, "defaultHeight": 48},
          "stream": {"source": "test", "encoder": "vp8", "producerId": "from-file"}})");
    const auto from_file = webrtc::create_webrtc_stream_from_config(settings.path());
    ASSERT_TRUE(from_file.has_value());
    EXPECT_EQ(from_file->get_producer_id(), "from-file");

    // A missing file falls back to the defaults, here with the source forced to the test pattern.
    const auto from_defaults = webrtc::create_webrtc_stream_from_config(kataglyphis::test::missing_path("w.json"),
      webrtc::VideoSource::TestPattern,
      webrtc::VideoEncoder::VP8,
      webrtc::ConfigOverrideMode::Override,
      webrtc::ConfigOverrideMode::Override);
    ASSERT_TRUE(from_defaults.has_value());
    EXPECT_TRUE(from_defaults->get_producer_id().starts_with("stream-"));
}
