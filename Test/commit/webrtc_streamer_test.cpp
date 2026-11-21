#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <future>
#include <initializer_list>
#include <iterator>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <tuple>
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
    EXPECT_EQ(config.producer_id, "producer");
    EXPECT_EQ(config.stun_servers, (std::vector<std::string>{ "stun:a", "stun:b" }));
    EXPECT_EQ(config.turn_servers, (std::vector<std::string>{ "turn:c" }));
}

// A field the pipeline text ignores is a setting that does nothing, as bitrate, TURN and the producer name once were.
TEST(WebRtcStreamConfig, EveryStreamSettingChangesThePipelineText)
{
    // Stops compiling when StreamConfig gains a field, so the table below grows with it.
    [[maybe_unused]] const auto &[source,
      encoder,
      signalling,
      producer,
      width,
      height,
      framerate,
      bitrate,
      camera,
      device,
      path,
      uri,
      stun,
      turn] = webrtc::StreamConfig{};
    using Change = void (*)(webrtc::StreamConfig &);
    const std::initializer_list<std::tuple<std::string_view, webrtc::VideoSource, Change>> rows{
        {
          "source",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.source = webrtc::VideoSource::TestPattern; },
        },
        {
          "encoder",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.encoder = webrtc::VideoEncoder::VP8; },
        },
        {
          "signalling_server_uri",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.signalling_server_uri = "wss://elsewhere/ws"; },
        },
        {
          "producer_id",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.producer_id = "garden cam"; },
        },
        {
          "width",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.width /= 2; },
        },
        {
          "height",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.height /= 2; },
        },
        {
          "framerate",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.framerate /= 2; },
        },
        {
          "bitrate_kbps",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.bitrate_kbps /= 4; },
        },
        {
          "camera_id",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.camera_id = "imx708"; },
        },
        {
          "v4l2_device",
          webrtc::VideoSource::V4L2,
          [](auto &config) -> void { config.v4l2_device = "/dev/video9"; },
        },
        {
          "input_path",
          webrtc::VideoSource::File,
          [](auto &config) -> void { config.input_path = "/clips/b.mp4"; },
        },
        {
          "input_uri",
          webrtc::VideoSource::Uri,
          [](auto &config) -> void { config.input_uri = "rtsp://cam/2"; },
        },
        {
          "stun_servers",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.stun_servers = { "stun://stun.example:3478" }; },
        },
        {
          "turn_servers",
          webrtc::VideoSource::Libcamera,
          [](auto &config) -> void { config.turn_servers = { "turn://user:secret@turn.example:3478" }; },
        },
    };
    EXPECT_EQ(rows.size(), 14U) << "one row per StreamConfig field";
    for (const auto &[field, kind, change] : rows) {
        webrtc::StreamConfig base;
        base.source = kind;
        base.input_path = "/clips/a.mp4";
        base.input_uri = "rtsp://cam/1";
        auto changed = base;
        change(changed);
        EXPECT_NE(webrtc::webrtc_pipeline_description(base), webrtc::webrtc_pipeline_description(changed)) << field;
    }
}

namespace {
// webrtcsink and the test source, which a streamer test needs; the same condition as the two skip macros.
auto streams_here() -> bool
{
    return webrtc::WebRTCStreamer::initialize()
           && kataglyphis::test::missing_gstreamer_element({ "videotestsrc", "videoconvert", "webrtcsink" }).empty();
}

// An error callback that, called from the loop thread, tries stop() and then request_stop(); true when refused.
auto stopping_from_its_error(webrtc::WebRTCStreamer &streamer) -> std::future<bool>
{
    const auto refused = std::make_shared<std::promise<bool>>();
    const auto asked = std::make_shared<std::atomic<bool>>(false);
    const auto test_thread = std::this_thread::get_id();
    streamer.set_error_callback(
      [&streamer, refused, asked, test_thread](webrtc::WebRTCError, const std::string &) -> void {
          // A start() that fails at once reports on the test's thread, which is no callback of the loop.
          if (std::this_thread::get_id() == test_thread || asked->exchange(true)) { return; }
          const bool stop_refused = !streamer.stop().has_value();
          streamer.request_stop();
          refused->set_value(stop_refused);
      });
    return refused->get_future();
}
}// namespace

// The error callback runs on the loop thread stop() joins: stop() there is refused, not the end of the process.
TEST(WebRtcStreamer, StopFromInsideACallbackIsRefused)
{
    if (!streams_here()) { GTEST_SKIP() << "webrtcsink or the test source is not installed here"; }
    webrtc::WebRTCStreamer streamer;
    // No signalling server listens there, so the stream fails and the bus calls back from the loop thread.
    auto refused = stopping_from_its_error(streamer);
    ASSERT_TRUE(streamer.configure(test_pattern_config()).has_value());
    // No skip, which the Linux lane refuses: a stream that failed before its loop ran has no loop to stop from.
    if (streamer.start().has_value()) {
        ASSERT_EQ(refused.wait_for(kataglyphis::test::kStreamTimeout), std::future_status::ready) << "no error came";
        EXPECT_TRUE(refused.get()) << "stop() from the error callback was not refused";
    }
    // From the owner's thread it tears down as always.
    EXPECT_TRUE(streamer.stop().has_value() && streamer.get_state() == webrtc::StreamState::Idle);
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
        { "h264", webrtc::VideoEncoder::H264 },
        // The names of the two H.264 choices webrtcsink never told apart.
        { "h264-hw", webrtc::VideoEncoder::H264 },
        { "h264-sw", webrtc::VideoEncoder::H264 },
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
      webrtc::VideoEncoder::H264,
      webrtc::ConfigOverrideMode::Override,
      webrtc::ConfigOverrideMode::Override);
    EXPECT_EQ(config.source, webrtc::VideoSource::Uri);
    EXPECT_EQ(config.encoder, webrtc::VideoEncoder::H264);

    const auto mixed = webrtc::create_stream_config_from_webrtc_config(settings,
      webrtc::VideoSource::Uri,
      webrtc::VideoEncoder::H264,
      webrtc::ConfigOverrideMode::UseConfig,
      webrtc::ConfigOverrideMode::Override);
    EXPECT_EQ(mixed.source, webrtc::VideoSource::V4L2);
    EXPECT_EQ(mixed.encoder, webrtc::VideoEncoder::H264);
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
    // The array and structure syntax webrtcsink parses: gst_parse_launch refuses a wrong one here.
    config.turn_servers = { "turn://user:secret@turn.example:3478", "turn://other.example:3478" };
    webrtc::WebRTCStreamer streamer;
    ASSERT_TRUE(streamer.configure(config).has_value());
    EXPECT_EQ(streamer.get_producer_id(), "kataglyphis-test");
    EXPECT_EQ(streamer.get_state(), webrtc::StreamState::Idle);
    // Configuring again replaces the pipeline and keeps the streamer usable.
    config.producer_id.clear();
    config.encoder = webrtc::VideoEncoder::H264;
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

TEST(WebRtcStreamer, AStartWithoutASignallingServerEndsInAnErrorThatStaysUntilStop)
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

    // A late PLAYING from the bus used to overwrite Error; now nothing follows it until stop().
    constexpr auto kLateMessages = std::chrono::milliseconds(300);
    std::this_thread::sleep_for(kLateMessages);
    EXPECT_EQ(streamer.get_state(), webrtc::StreamState::Error);
    {
        const std::scoped_lock lock(mutex);
        const auto error_at = std::ranges::find(states, webrtc::StreamState::Error);
        ASSERT_NE(error_at, states.end());
        EXPECT_EQ(std::next(error_at), states.end());
    }

    // A retry without stop() is refused: a second loop thread over the first one would end the process.
    EXPECT_EQ(kataglyphis::test::error_of(streamer.start()), webrtc::WebRTCError::StateChangeFailed);

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

TEST(WebRTCError, EveryValueHasANameOfItsOwn)
{
    const auto names = kataglyphis::test::names_of<kataglyphis::webrtc::WebRTCError>();
    ASSERT_EQ(names.size(), 5U);
    EXPECT_EQ(names.front(), "InitializationFailed");
    EXPECT_EQ(names.back(), "InvalidConfiguration");
    EXPECT_TRUE(kataglyphis::test::all_differ(names));
    EXPECT_EQ(to_string(static_cast<kataglyphis::webrtc::WebRTCError>(1)), "UnknownError");
    EXPECT_EQ(to_string(static_cast<kataglyphis::webrtc::WebRTCError>(9)), "UnknownError");
}

namespace {

enum class LeakCheck : std::uint8_t { On, Off };

// gst_deinit and the first gst_init are once per process, so each case runs in a child of its own.
template<typename Case> void in_a_child(Case scenario, LeakCheck leak_check = LeakCheck::On)
{
    EXPECT_EXIT(
      {
          scenario();
          const int code = ::testing::Test::HasFailure() ? 1 : 0;
          // _Exit skips LeakSanitizer's exit check, which would read an in-process plugin scan's allocations as ours.
          if (leak_check == LeakCheck::Off) { std::_Exit(code); }
          std::exit(code);
      },
      ::testing::ExitedWithCode(0),
      "");
}

void set_variable(const char *name, const std::string &value)
{
#ifdef _WIN32
    ASSERT_EQ(_putenv_s(name, value.c_str()), 0);
#else
    ASSERT_EQ(setenv(name, value.c_str(), 1), 0);
#endif
}

}// namespace

TEST(GStreamerRuntime, DeinitialiseWithALivePipelineIsRefused)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("fakesrc", "fakesink");
    in_a_child([] -> void {
        ASSERT_TRUE(kataglyphis::gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
        {
            kataglyphis::gstreamer::GStreamerPipeline pipeline;
            ASSERT_TRUE(pipeline.create_pipeline({ "fakesrc num-buffers=1 ! fakesink" }).has_value());
            EXPECT_FALSE(kataglyphis::gstreamer::GStreamerPipeline::deinitialize_gstreamer());
            EXPECT_FALSE(webrtc::WebRTCStreamer::deinitialize());
        }
        EXPECT_TRUE(kataglyphis::gstreamer::GStreamerPipeline::deinitialize_gstreamer());
    });
}

TEST(GStreamerRuntime, InitialiseAfterDeinitialiseFails)
{
    in_a_child([] -> void {
        ASSERT_TRUE(kataglyphis::gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
        ASSERT_TRUE(kataglyphis::gstreamer::GStreamerPipeline::deinitialize_gstreamer());
        EXPECT_FALSE(kataglyphis::gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
        EXPECT_FALSE(webrtc::WebRTCStreamer::initialize().has_value());
        EXPECT_FALSE(kataglyphis::gstreamer::GStreamerPipeline::deinitialize_gstreamer());
    });
}

TEST(GStreamerRuntime, TheScannerFailureIsSeenWhicheverClassInitialisesFirst)
{
#ifdef _WIN32
    GTEST_SKIP() << "the bundled GStreamer names its own scanner on Windows";
#endif
    in_a_child(
      [] -> void {
          // A fresh registry makes GStreamer scan, and a scanner that is not there makes it scan in process.
          const auto registry = std::filesystem::temp_directory_path()
                                / ("kataglyphis-registry-" + std::to_string(std::random_device{}()) + ".bin");
          set_variable("GST_REGISTRY", registry.string());
          set_variable("GST_PLUGIN_SCANNER", "/nonexistent/gst-plugin-scanner");
          // The riscv64 lane sets GST_REGISTRY_FORK=no (hub riscv64-cross.sh), which never starts a scanner to fail.
          set_variable("GST_REGISTRY_FORK", "yes");
          ASSERT_TRUE(kataglyphis::gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
          EXPECT_TRUE(webrtc::WebRTCStreamer::plugin_scanner_failed());
          std::error_code ignored;
          std::filesystem::remove(registry, ignored);
      },
      LeakCheck::Off);
}
