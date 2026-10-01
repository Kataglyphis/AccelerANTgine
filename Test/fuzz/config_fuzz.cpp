#include "kataglyphis_test_support.h"

#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

#include <cstdint>
#include <limits>
#include <string>
#include <string_view>

#include "kShippedInferenceConfig.inc"

import kataglyphis.config_loader;
import kataglyphis.toml_config;
import kataglyphis.webrtc_streamer;
import kataglyphis.yolo_detector;

namespace cfg = kataglyphis::config;
namespace webrtc = kataglyphis::webrtc;

namespace {

constexpr std::string_view kSettingsSeed =
  R"({"signalingServerUrl": "ws://127.0.0.1:8443", "reconnectionTimeoutMs": 5000, "stunServers": ["stun:a"],
      "video": {"defaultWidth": 1280, "defaultHeight": 720}, "texture": {"width": 640},
      "android": {"fps": 15}, "stream": {"source": "test", "encoder": "vp8", "producerId": "p"}})";

// JSON-escapes printable ASCII, the only characters the domain below produces.
auto json_string(std::string_view text) -> std::string
{
    std::string quoted = "\"";
    for (const char ch : text) {
        if (ch == '"' || ch == '\\') { quoted.push_back('\\'); }
        quoted.push_back(ch);
    }
    quoted.push_back('"');
    return quoted;
}

}// namespace

// Untrusted settings files: any bytes either parse or come back as an error, never a crash or a hang.
void ParseWebRtcSettingsNeverCrashes(const std::string &bytes)
{
    const auto config = cfg::parse_webrtc_config(bytes);
    if (!config.has_value()) {
        EXPECT_TRUE(config.error() == cfg::ConfigError::ParseError || config.error() == cfg::ConfigError::InvalidValue);
    }
}
FUZZ_TEST(ConfigFuzz, ParseWebRtcSettingsNeverCrashes)
  .WithSeeds({ { std::string(kSettingsSeed) }, { "{}" }, { "[]" }, { R"({"video": {"defaultWidth": -1}})" } });

// Every unsigned field holds exactly what the file says, or the file is rejected; nothing wraps.
void UnsignedSettingsRoundTripOrAreRejected(std::uint64_t value)
{
    const auto config = cfg::parse_webrtc_config(R"({"texture": {"width": )" + std::to_string(value) + "}}");
    if (value <= std::numeric_limits<std::uint32_t>::max()) {
        ASSERT_TRUE(config.has_value()) << value;
        EXPECT_EQ(config->texture.width, value);
    } else {
        ASSERT_FALSE(config.has_value()) << value;
        EXPECT_EQ(config.error(), cfg::ConfigError::InvalidValue);
    }
}
FUZZ_TEST(ConfigFuzz, UnsignedSettingsRoundTripOrAreRejected)
  .WithSeeds({ { 0U }, { 4294967295ULL }, { 4294967296ULL }, { std::numeric_limits<std::uint64_t>::max() } });

void StringSettingsRoundTrip(const std::string &text)
{
    const auto config = cfg::parse_webrtc_config(R"({"stream": {"device": )" + json_string(text) + "}}");
    ASSERT_TRUE(config.has_value()) << text;
    EXPECT_EQ(config->stream.device, text);
}
FUZZ_TEST(ConfigFuzz, StringSettingsRoundTrip).WithDomains(fuzztest::PrintableAsciiString());

// Untrusted inference configs, the same contract for the TOML parser.
void ParseInferenceConfigNeverCrashes(const std::string &bytes)
{
    const auto config = cfg::parse_inference_config(bytes);
    if (!config.has_value()) { EXPECT_EQ(config.error(), cfg::TomlConfigError::ParseError); }
}
FUZZ_TEST(ConfigFuzz, ParseInferenceConfigNeverCrashes)
  .WithSeeds({ { std::string(kShippedInferenceConfig) }, { "[model]\ninput_width = 320\n" }, { "" } });

// An integer the uint32 fields cannot hold falls back to the default instead of wrapping.
void TomlUnsignedFieldsTakeOnlyTheirRange(std::int64_t value)
{
    const auto config = cfg::parse_inference_config("[model]\ninput_width = " + std::to_string(value) + "\n");
    ASSERT_TRUE(config.has_value()) << value;
    if (value >= 0 && value <= std::numeric_limits<std::uint32_t>::max()) {
        EXPECT_EQ(config->model.input_width, static_cast<std::uint64_t>(value));
    } else {
        EXPECT_EQ(config->model.input_width, 640U) << value;
    }
}
FUZZ_TEST(ConfigFuzz, TomlUnsignedFieldsTakeOnlyTheirRange)
  .WithSeeds({ { 0 }, { -1 }, { 4294967295LL }, { 4294967296LL }, { std::numeric_limits<std::int64_t>::min() } });

// The settings' free-text source and encoder names map to an enum for every input.
void StreamNamesAlwaysMap(const std::string &source, const std::string &encoder)
{
    cfg::WebRTCConfig settings;
    settings.stream.source = source;
    settings.stream.encoder = encoder;
    const auto config = webrtc::create_stream_config_from_webrtc_config(
      settings, webrtc::VideoSource::TestPattern, webrtc::VideoEncoder::VP9);
    const bool known_source =
      source == "libcamera" || source == "v4l2" || source == "test" || source == "file" || source == "uri";
    const bool known_encoder = encoder == "h264-hw" || encoder == "h264-sw" || encoder == "vp8" || encoder == "vp9";
    if (!known_source) { EXPECT_EQ(config.source, webrtc::VideoSource::TestPattern); }
    if (!known_encoder) { EXPECT_EQ(config.encoder, webrtc::VideoEncoder::VP9); }
}
FUZZ_TEST(ConfigFuzz, StreamNamesAlwaysMap)
  .WithSeeds({ { "libcamera", "h264-hw" }, { "v4l2", "vp8" }, { "file", "h264-sw" }, { "camera", "h265" } });

void CocoClassNamesAreTotal(int class_id)
{
    const auto name = kataglyphis::detection::YoloDetector::get_coco_class_name(class_id);
    EXPECT_FALSE(name.empty());
    EXPECT_EQ(name == "unknown", class_id < 0 || class_id >= 80) << class_id;
}
FUZZ_TEST(ConfigFuzz, CocoClassNamesAreTotal);
