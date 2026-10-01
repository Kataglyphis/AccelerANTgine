#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

import kataglyphis.gstreamer_pipeline;

#include "gstreamer_test_support.h"

namespace gstreamer = kataglyphis::gstreamer;
using kataglyphis::test::error_of;
using kataglyphis::test::EventCounter;
using kataglyphis::test::kStreamTimeout;

namespace {

// GstState values the API hands out as int.
constexpr int kStateNull = 1;
constexpr int kStatePlaying = 4;

// videotestsrc rounds each timestamp down, so the durations at 30 fps alternate between ...33 and ...34.
constexpr auto frame_start_30fps(std::uint64_t frame) -> std::uint64_t { return frame * 1000000000ULL / 30U; }

constexpr std::string_view kThreeBlackFrames =
  "videotestsrc num-buffers=3 pattern=black ! video/x-raw,format=RGBA,width=8,height=4,framerate=30/1 "
  "! appsink name=sink sync=false";

}// namespace

TEST(GStreamerPipeline, InitializeIsIdempotent)
{
    EXPECT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
    EXPECT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
}

TEST(GStreamerPipeline, AnEmptyPipelineRefusesEveryOperation)
{
    gstreamer::GStreamerPipeline pipeline;
    EXPECT_FALSE(pipeline.is_playing());
    EXPECT_FALSE(pipeline.is_paused());
    EXPECT_EQ(pipeline.get_current_state(), kStateNull);
    EXPECT_TRUE(pipeline.get_caps_string().empty());
    EXPECT_TRUE(pipeline.stop().has_value());

    EXPECT_EQ(error_of(pipeline.start()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.pause()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.resume()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.get_position_ns()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.get_duration_ns()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.seek(0)), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.pull_sample(10)), gstreamer::GStreamerError::ElementCreationFailed);

    std::array<std::byte, 4> payload{};
    EXPECT_EQ(error_of(pipeline.push_buffer(payload.data(), payload.size(), {})),
      gstreamer::GStreamerError::ElementCreationFailed);
}

TEST(GStreamerPipeline, AnUnknownElementIsPipelineCreationFailed)
{
    ASSERT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
    gstreamer::GStreamerPipeline pipeline;
    const auto result = pipeline.create_pipeline_from_string("kataglyphis_no_such_element ! fakesink");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(error_of(pipeline.start()), gstreamer::GStreamerError::PipelineCreationFailed);
}

TEST(GStreamerPipeline, ABadPropertyIsPipelineCreationFailed)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("fakesrc", "fakesink");
    gstreamer::GStreamerPipeline pipeline;
    const auto result = pipeline.create_pipeline_from_string("fakesrc kataglyphis-no-such-property=1 ! fakesink");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), gstreamer::GStreamerError::PipelineCreationFailed);
}

TEST(GStreamerPipeline, PullsFramesWithTheirMetadata)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    gstreamer::PipelineConfig config;
    config.pipeline_description = std::string(kThreeBlackFrames);
    ASSERT_TRUE(pipeline.create_pipeline(config).has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(pipeline.is_playing());

    for (std::uint64_t frame = 0; frame < 3; ++frame) {
        const auto sample = pipeline.pull_sample(static_cast<std::uint32_t>(kStreamTimeout.count()));
        ASSERT_TRUE(sample.has_value()) << "frame " << frame;
        EXPECT_EQ(sample->size, 8U * 4U * 4U);
        ASSERT_EQ(sample->data.size(), sample->size);
        EXPECT_EQ(sample->metadata.width, 8U);
        EXPECT_EQ(sample->metadata.height, 4U);
        EXPECT_EQ(sample->metadata.format, "RGBA");
        EXPECT_EQ(sample->metadata.fps_n, 30U);
        EXPECT_EQ(sample->metadata.fps_d, 1U);
        EXPECT_EQ(sample->metadata.timestamp_ns, frame_start_30fps(frame));
        EXPECT_EQ(sample->metadata.duration_ns, frame_start_30fps(frame + 1) - frame_start_30fps(frame));
        EXPECT_TRUE(sample->tensors.empty());
        // Black RGBA: zero colour, opaque alpha.
        EXPECT_EQ(sample->data[0], std::byte{ 0 });
        EXPECT_EQ(sample->data[3], std::byte{ 0xFF });
    }

    // After the last buffer the stream is at EOS, which pull_sample reports instead of blocking.
    EXPECT_EQ(error_of(pipeline.pull_sample(static_cast<std::uint32_t>(kStreamTimeout.count()))),
      gstreamer::GStreamerError::BufferAllocationFailed);
    EXPECT_TRUE(pipeline.stop().has_value());
    EXPECT_FALSE(pipeline.is_playing());
    EXPECT_EQ(pipeline.get_current_state(), kStateNull);
}

TEST(GStreamerPipeline, PullingWithoutATimeoutWaitsForTheNextFrame)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    const auto sample = pipeline.pull_sample(0);
    ASSERT_TRUE(sample.has_value());
    EXPECT_EQ(sample->metadata.timestamp_ns, 0U);
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, DeliversEveryFrameToTheCallback)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());

    EventCounter frames;
    std::mutex seen_mutex;
    std::vector<std::uint64_t> timestamps;
    pipeline.set_buffer_callback([&](const gstreamer::BufferInfo &buffer) {
        {
            std::scoped_lock lock(seen_mutex);
            timestamps.push_back(buffer.metadata.timestamp_ns);
        }
        frames.add();
    });
    // A second registration replaces the first; it must not deliver each frame twice.
    pipeline.set_buffer_callback([&](const gstreamer::BufferInfo &buffer) {
        {
            std::scoped_lock lock(seen_mutex);
            timestamps.push_back(buffer.metadata.timestamp_ns);
        }
        frames.add();
    });

    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(frames.wait_for(3, kStreamTimeout));
    EXPECT_TRUE(pipeline.stop().has_value());

    std::scoped_lock lock(seen_mutex);
    EXPECT_EQ(timestamps, (std::vector<std::uint64_t>{ 0, frame_start_30fps(1), frame_start_30fps(2) }));
}

TEST(GStreamerPipeline, ACallbackSetBeforeThePipelineStillGetsFrames)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    EventCounter frames;
    pipeline.set_buffer_callback([&](const gstreamer::BufferInfo &) { frames.add(); });
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(frames.wait_for(3, kStreamTimeout));
    EXPECT_TRUE(pipeline.stop().has_value());
    EXPECT_EQ(frames.count(), 3);
}

TEST(GStreamerPipeline, PushedBuffersComeOutUnchanged)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("appsrc", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline
        .create_pipeline_from_string("appsrc name=src format=time "
                                     "caps=video/x-raw,format=GRAY8,width=4,height=2,framerate=0/1 "
                                     "! appsink name=sink sync=false")
        .has_value());
    ASSERT_TRUE(pipeline.start().has_value());

    for (std::uint8_t frame = 0; frame < 2; ++frame) {
        std::array<std::uint8_t, 8> pixels{};
        for (std::size_t i = 0; i < pixels.size(); ++i) { pixels[i] = static_cast<std::uint8_t>(frame * 16 + i); }
        gstreamer::FrameMetadata metadata;
        metadata.timestamp_ns = 1000U * frame;
        metadata.duration_ns = 1000;
        ASSERT_TRUE(pipeline.push_buffer(pixels.data(), pixels.size(), metadata).has_value());

        const auto sample = pipeline.pull_sample(static_cast<std::uint32_t>(kStreamTimeout.count()));
        ASSERT_TRUE(sample.has_value());
        ASSERT_EQ(sample->size, pixels.size());
        for (std::size_t i = 0; i < pixels.size(); ++i) {
            EXPECT_EQ(sample->data[i], static_cast<std::byte>(pixels[i])) << "byte " << i;
        }
        EXPECT_EQ(sample->metadata.timestamp_ns, 1000U * frame);
        EXPECT_EQ(sample->metadata.duration_ns, 1000U);
        EXPECT_EQ(sample->metadata.width, 4U);
        EXPECT_EQ(sample->metadata.height, 2U);
        EXPECT_EQ(sample->metadata.format, "GRAY8");
    }
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, APipelineWithoutAppElementsHasNothingToPullOrPush)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("fakesrc", "fakesink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string("fakesrc num-buffers=1 ! fakesink").has_value());
    EXPECT_EQ(error_of(pipeline.pull_sample(10)), gstreamer::GStreamerError::ElementCreationFailed);
    std::array<std::byte, 4> payload{};
    EXPECT_EQ(error_of(pipeline.push_buffer(payload.data(), payload.size(), {})),
      gstreamer::GStreamerError::ElementCreationFailed);
}

TEST(GStreamerPipeline, PauseAndResumeTrackTheState)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "fakesink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string("videotestsrc is-live=true ! fakesink").has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(pipeline.is_playing());
    EXPECT_FALSE(pipeline.is_paused());

    ASSERT_TRUE(pipeline.pause().has_value());
    EXPECT_TRUE(pipeline.is_paused());
    EXPECT_FALSE(pipeline.is_playing());

    ASSERT_TRUE(pipeline.resume().has_value());
    EXPECT_TRUE(pipeline.is_playing());
    EXPECT_FALSE(pipeline.is_paused());

    ASSERT_TRUE(pipeline.stop().has_value());
    EXPECT_FALSE(pipeline.is_playing());
    EXPECT_FALSE(pipeline.is_paused());
}

TEST(GStreamerPipeline, ReportsPlayingOnceThePipelineGetsThere)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "fakesink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string("videotestsrc ! fakesink sync=false").has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    // get_current_state() does not wait, so poll until the asynchronous state change lands.
    const auto deadline = std::chrono::steady_clock::now() + kStreamTimeout;
    while (pipeline.get_current_state() != kStatePlaying && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(pipeline.get_current_state(), kStatePlaying);
    EXPECT_TRUE(pipeline.get_position_ns().has_value());
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, ReplacingThePipelineReleasesTheOldOne)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink", "appsrc");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    ASSERT_TRUE(
      pipeline.create_pipeline_from_string("appsrc name=src format=time ! appsink name=sink sync=false").has_value());
    // The new pipeline is idle; its appsink, not the old one, answers.
    EXPECT_FALSE(pipeline.is_playing());
    ASSERT_TRUE(pipeline.start().has_value());
    std::array<std::uint8_t, 3> payload{ 1, 2, 3 };
    ASSERT_TRUE(pipeline.push_buffer(payload.data(), payload.size(), {}).has_value());
    const auto sample = pipeline.pull_sample(static_cast<std::uint32_t>(kStreamTimeout.count()));
    ASSERT_TRUE(sample.has_value());
    EXPECT_EQ(sample->size, payload.size());
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, AMovedPipelineKeepsStreaming)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    gstreamer::GStreamerPipeline moved(std::move(pipeline));
    ASSERT_TRUE(moved.start().has_value());
    EXPECT_TRUE(moved.pull_sample(static_cast<std::uint32_t>(kStreamTimeout.count())).has_value());
    EXPECT_TRUE(moved.stop().has_value());
}

TEST(GStreamerPipeline, TheInferencePipelineNeedsNnstreamer)
{
    ASSERT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
    if (kataglyphis::test::missing_gstreamer_element({ "tensor_transform", "onnxruntime" }).empty()) {
        GTEST_SKIP() << "nnstreamer's tensor_transform and onnxruntime are installed; this covers their absence";
    }
    gstreamer::GStreamerPipeline pipeline;
    const auto result = pipeline.create_inference_pipeline("videotestsrc", "model.onnx", { 1, 3, 480, 640 });
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), gstreamer::GStreamerError::PipelineCreationFailed);

    const auto video = gstreamer::create_video_inference_pipeline("clip.mp4", "model.onnx", 64, 48);
    ASSERT_FALSE(video.has_value());
    EXPECT_EQ(video.error(), gstreamer::GStreamerError::PipelineCreationFailed);

    const auto camera = gstreamer::create_camera_inference_pipeline("/dev/video0", "model.onnx", 64, 48, 30);
    ASSERT_FALSE(camera.has_value());
    EXPECT_EQ(camera.error(), gstreamer::GStreamerError::PipelineCreationFailed);
}
