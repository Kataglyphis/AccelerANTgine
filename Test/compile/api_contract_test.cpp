#include "kataglyphis_c_api.h"
#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <cstddef>
#include <filesystem>
#include <string>
#include <type_traits>

// Every module in one translation unit: they must coexist, as they do in an embedder.
import kataglyphis.c_api;
import kataglyphis.config_loader;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.inference;
import kataglyphis.onnx_inference;
import kataglyphis.project_config;
import kataglyphis.text_generation;
import kataglyphis.toml_config;
import kataglyphis.webrtc_streamer;
import kataglyphis.yolo_detector;

extern "C" int kataglyphis_c_header_consumer_add(int lhs, int rhs);
extern "C" int
  kataglyphis_c_header_consumer_generate(const char *model_dir, size_t *bytes, kataglyphis_text_stats *stats);

namespace {

template<typename T>
constexpr bool kMoveOnly = !std::is_copy_constructible_v<T> && !std::is_copy_assignable_v<T>
                           && std::is_nothrow_move_constructible_v<T> && std::is_nothrow_move_assignable_v<T>;

template<typename Enum> constexpr auto as_int(Enum value) -> int { return static_cast<int>(value); }

}// namespace

namespace inference = kataglyphis::inference;
namespace detection = kataglyphis::detection;
namespace gstreamer = kataglyphis::gstreamer;
namespace webrtc = kataglyphis::webrtc;
namespace cfg = kataglyphis::config;
namespace text = kataglyphis::text;

TEST(CApiContract, TheHeaderCompilesAsCAndLinks) { EXPECT_EQ(kataglyphis_c_header_consumer_add(20, 22), 42); }

TEST(CApiContract, TheModuleExportsTheSameFunction)
{
    // The Linux plugin reaches the C API through `import kataglyphis.c_api;`, the Windows one through the header.
    EXPECT_EQ(kataglyphis_add(20, 22), kataglyphis_c_header_consumer_add(20, 22));
}

TEST(CApiContract, TheCHeaderDrivesTextGeneration)
{
    std::size_t bytes = 0;
    kataglyphis_text_stats stats{};
    ASSERT_EQ(kataglyphis_c_header_consumer_generate(
                kataglyphis::test::tiny_genai_model_dir().string().c_str(), &bytes, &stats),
      KATAGLYPHIS_TEXT_OK);
    EXPECT_EQ(bytes, 4U);
    EXPECT_EQ(stats.completion_tokens, 4U);
    EXPECT_EQ(stats.prompt_tokens, 3U);
    EXPECT_EQ(stats.finish_reason, KATAGLYPHIS_TEXT_FINISH_LENGTH);
}

TEST(CApiContract, TextStatusesAreTheCppErrorsShiftedByOne)
{
    // The C codes are an ABI: a reordered TextGenError would renumber them for every embedder.
    static_assert(KATAGLYPHIS_TEXT_OK == 0);
    static_assert(as_int(text::TextGenError::LibraryUnavailable) + 1 == KATAGLYPHIS_TEXT_LIBRARY_UNAVAILABLE);
    static_assert(as_int(text::TextGenError::ModelLoadFailed) + 1 == KATAGLYPHIS_TEXT_MODEL_LOAD_FAILED);
    static_assert(as_int(text::TextGenError::ProviderUnavailable) + 1 == KATAGLYPHIS_TEXT_PROVIDER_UNAVAILABLE);
    static_assert(as_int(text::TextGenError::TokenizerFailed) + 1 == KATAGLYPHIS_TEXT_TOKENIZER_FAILED);
    static_assert(as_int(text::TextGenError::ChatTemplateFailed) + 1 == KATAGLYPHIS_TEXT_CHAT_TEMPLATE_FAILED);
    static_assert(as_int(text::TextGenError::EncodeFailed) + 1 == KATAGLYPHIS_TEXT_ENCODE_FAILED);
    static_assert(as_int(text::TextGenError::InvalidOptions) + 1 == KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    static_assert(as_int(text::TextGenError::GenerationFailed) + 1 == KATAGLYPHIS_TEXT_GENERATION_FAILED);
    static_assert(as_int(text::TextGenError::NotInitialized) + 1 == KATAGLYPHIS_TEXT_NOT_INITIALIZED);
    for (int status = KATAGLYPHIS_TEXT_LIBRARY_UNAVAILABLE; status <= KATAGLYPHIS_TEXT_NOT_INITIALIZED; ++status) {
        EXPECT_EQ(std::string(kataglyphis_text_status_message(status)),
          std::string(text::to_string(static_cast<text::TextGenError>(status - 1))));
    }
    EXPECT_EQ(std::string(kataglyphis_text_status_message(KATAGLYPHIS_TEXT_OK)), "success");
    EXPECT_EQ(std::string(kataglyphis_text_status_message(-1)), "unknown status");
    EXPECT_EQ(std::string(kataglyphis_text_status_message(KATAGLYPHIS_TEXT_NOT_INITIALIZED + 1)), "unknown status");
}

TEST(CApiContract, TextOptionDefaultsAreTheCppDefaults)
{
    kataglyphis_text_options options{};
    kataglyphis_text_options_default(&options);
    const text::GenerationOptions defaults;
    EXPECT_EQ(options.max_new_tokens, defaults.max_new_tokens);
    EXPECT_DOUBLE_EQ(options.temperature, defaults.temperature);
    EXPECT_DOUBLE_EQ(options.top_p, defaults.top_p);
    EXPECT_EQ(options.top_k, defaults.top_k);
    EXPECT_EQ(defaults.max_new_tokens, 128);
    EXPECT_DOUBLE_EQ(defaults.temperature, 0.0);
}

TEST(CppApiContract, ResourceOwnersAreMoveOnly)
{
    static_assert(kMoveOnly<inference::OnnxInferenceEngine>);
    static_assert(kMoveOnly<detection::YoloDetector>);
    static_assert(kMoveOnly<detection::VideoDetectorPipeline>);
    static_assert(kMoveOnly<gstreamer::GStreamerPipeline>);
    static_assert(kMoveOnly<webrtc::WebRTCStreamer>);
    static_assert(kMoveOnly<text::TextGenerator>);
    SUCCEED();
}

TEST(CppApiContract, ErrorCodesKeepTheirNumbers)
{
    // The CLI and the demo print errors as integers, so a reordered enum silently changes what they report.
    static_assert(as_int(inference::OnnxError::SessionCreationFailed) == 0);
    static_assert(as_int(inference::OnnxError::ModelLoadFailed) == 1);
    static_assert(as_int(inference::OnnxError::InferenceFailed) == 4);
    static_assert(as_int(inference::OnnxError::InvalidInputShape) == 5);
    static_assert(as_int(inference::OnnxError::SessionNotInitialized) == 8);
    static_assert(as_int(inference::OnnxError::OutputNotFound) == 9);
    static_assert(as_int(gstreamer::GStreamerError::InitializationFailed) == 0);
    static_assert(as_int(gstreamer::GStreamerError::PipelineCreationFailed) == 1);
    static_assert(as_int(gstreamer::GStreamerError::ResourceNotFound) == 9);
    static_assert(as_int(webrtc::WebRTCError::InitializationFailed) == 0);
    static_assert(as_int(webrtc::WebRTCError::InvalidConfiguration) == 8);
    static_assert(as_int(webrtc::WebRTCError::Timeout) == 9);
    static_assert(as_int(cfg::ConfigError::FileNotFound) == 0);
    static_assert(as_int(cfg::ConfigError::InvalidValue) == 3);
    static_assert(as_int(cfg::TomlConfigError::ParseError) == 1);
    static_assert(as_int(webrtc::StreamState::Idle) == 0);
    static_assert(as_int(webrtc::StreamState::Disconnected) == 6);
    static_assert(std::is_same_v<detection::OnnxError, inference::OnnxError>);
    SUCCEED();
}

TEST(CppApiContract, ConfigurationDefaults)
{
    const inference::SessionConfig session;
    EXPECT_TRUE(session.model_path.empty());
    EXPECT_EQ(session.intra_op_num_threads, 4);
    EXPECT_EQ(session.inter_op_num_threads, 4);
    EXPECT_FALSE(session.enable_cuda);
    EXPECT_TRUE(session.enable_memory_pattern);
    EXPECT_EQ(session.execution_mode, inference::ExecutionMode::Sequential);

    const detection::YoloConfig yolo;
    EXPECT_FLOAT_EQ(yolo.confidence_threshold, 0.25F);
    EXPECT_FLOAT_EQ(yolo.nms_threshold, 0.45F);
    EXPECT_EQ(yolo.input_width, 640U);
    EXPECT_EQ(yolo.input_height, 640U);
    EXPECT_EQ(yolo.num_classes, 80);

    const detection::BoundingBox box;
    EXPECT_EQ(box.class_id, -1);
    EXPECT_TRUE(box.class_name.empty());

    const detection::VideoDetectionConfig video;
    EXPECT_FALSE(video.display_results);
    EXPECT_FALSE(video.save_to_file);
    EXPECT_EQ(video.output_path, std::filesystem::path("output.mp4"));

    const gstreamer::PipelineConfig pipeline;
    EXPECT_TRUE(pipeline.pipeline_description.empty());
    EXPECT_FALSE(pipeline.enable_tensor_meta);
    EXPECT_TRUE(pipeline.synchronous_mode);
    EXPECT_EQ(pipeline.timeout_ms, 5000U);

    const gstreamer::FrameMetadata frame;
    EXPECT_EQ(frame.fps_n, 0U);
    EXPECT_EQ(frame.fps_d, 1U);

    const webrtc::StreamConfig stream;
    EXPECT_EQ(stream.source, webrtc::VideoSource::Libcamera);
    EXPECT_EQ(stream.encoder, webrtc::VideoEncoder::H264_Hardware);
    EXPECT_EQ(stream.signalling_server_uri, "ws://127.0.0.1:8443");
    EXPECT_EQ(stream.width, 1280U);
    EXPECT_EQ(stream.height, 720U);
    EXPECT_EQ(stream.framerate, 30U);
    EXPECT_EQ(stream.bitrate_kbps, 2000U);
    EXPECT_EQ(stream.v4l2_device, "/dev/video0");
}

TEST(CppApiContract, TheSettingsDefaultsAgreeWithTheStreamDefaults)
{
    // The CLI turns get_default_webrtc_config() into a StreamConfig; both sides must describe the same stream.
    const auto settings = cfg::get_default_webrtc_config();
    const auto stream = webrtc::create_stream_config_from_webrtc_config(settings);
    const webrtc::StreamConfig defaults;
    EXPECT_EQ(stream.signalling_server_uri, defaults.signalling_server_uri);
    EXPECT_EQ(stream.width, defaults.width);
    EXPECT_EQ(stream.height, defaults.height);
    EXPECT_EQ(stream.framerate, defaults.framerate);
    EXPECT_EQ(stream.bitrate_kbps, defaults.bitrate_kbps);
    EXPECT_EQ(stream.v4l2_device, defaults.v4l2_device);
    EXPECT_EQ(stream.source, defaults.source);
    EXPECT_EQ(stream.encoder, defaults.encoder);
}

TEST(CppApiContract, TheProjectConfigNamesTheBuiltVersion)
{
    const std::string version = std::string(kataglyphis::project_config::project_version_major) + "."
                                + kataglyphis::project_config::project_version_minor;
    EXPECT_EQ(version, KATAGLYPHIS_TEST_PROJECT_VERSION);
    EXPECT_EQ(inference::MyCalculator{}.version(), version);
}
