#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <future>
#include <initializer_list>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

import kataglyphis.gstreamer_pipeline;

#include "gstreamer_test_support.h"

namespace gstreamer = kataglyphis::gstreamer;
using kataglyphis::test::EventCounter;

namespace {

// GstState values the API hands out as int.

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
    EXPECT_TRUE(pipeline.stop().has_value());

    EXPECT_EQ(kataglyphis::test::error_of(pipeline.start()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(kataglyphis::test::error_of(pipeline.pause()), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(kataglyphis::test::error_of(pipeline.pull_sample(10)), gstreamer::GStreamerError::ElementCreationFailed);
}

TEST(GStreamerPipeline, AnUnknownElementIsPipelineCreationFailed)
{
    ASSERT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
    gstreamer::GStreamerPipeline pipeline;
    const auto result = pipeline.create_pipeline_from_string("kataglyphis_no_such_element ! fakesink");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), gstreamer::GStreamerError::PipelineCreationFailed);
    EXPECT_EQ(kataglyphis::test::error_of(pipeline.start()), gstreamer::GStreamerError::PipelineCreationFailed);
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
        const auto sample = pipeline.pull_sample(static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count()));
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
    EXPECT_EQ(kataglyphis::test::error_of(
                pipeline.pull_sample(static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count()))),
      gstreamer::GStreamerError::BufferAllocationFailed);
    EXPECT_TRUE(pipeline.stop().has_value());
    EXPECT_FALSE(pipeline.is_playing());

    // Back in NULL, the next start replays the stream from its first frame.
    ASSERT_TRUE(pipeline.start().has_value());
    const auto first = pipeline.pull_sample(static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count()));
    ASSERT_TRUE(first.has_value());
    EXPECT_EQ(first->metadata.timestamp_ns, frame_start_30fps(0));
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, AStreamThatEndsSaysSoAndARestartForgetsIt)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    EXPECT_FALSE(pipeline.has_ended());
    ASSERT_TRUE(pipeline.start().has_value());
    const auto timeout = static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count());
    for (int frame = 0; frame < 3; ++frame) { ASSERT_TRUE(pipeline.pull_sample(timeout).has_value()); }
    // The end is no error: the caller of a file sees it as the stream's end, not as a failure.
    EXPECT_EQ(
      kataglyphis::test::error_of(pipeline.pull_sample(timeout)), gstreamer::GStreamerError::BufferAllocationFailed);
    const auto deadline = std::chrono::steady_clock::now() + kataglyphis::test::kStreamTimeout;
    while (!pipeline.has_ended() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    EXPECT_TRUE(pipeline.has_ended());
    EXPECT_FALSE(pipeline.stream_error().has_value());
    EXPECT_TRUE(pipeline.stop().has_value());

    // An endless stream, so the restart cannot have ended again by the time it is asked.
    ASSERT_TRUE(pipeline
        .create_pipeline_from_string("videotestsrc is-live=true pattern=black "
                                     "! video/x-raw,format=RGBA,width=8,height=4,framerate=30/1 "
                                     "! appsink name=sink sync=false max-buffers=1 drop=true")
        .has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    ASSERT_TRUE(pipeline.pull_sample(timeout).has_value());
    EXPECT_FALSE(pipeline.has_ended());
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, AnErrorUpstreamIsAStreamErrorThatNamesItsElement)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "identity", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    // identity fails at its second buffer, as a camera does when it is unplugged.
    ASSERT_TRUE(pipeline
        .create_pipeline_from_string("videotestsrc pattern=black "
                                     "! video/x-raw,format=RGBA,width=8,height=4,framerate=30/1 "
                                     "! identity name=unplugged error-after=2 ! appsink name=sink sync=false")
        .has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    const auto timeout = static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count());
    ASSERT_TRUE(pipeline.pull_sample(timeout).has_value());
    EXPECT_EQ(kataglyphis::test::error_of(pipeline.pull_sample(timeout)), gstreamer::GStreamerError::StreamError);
    EXPECT_TRUE(pipeline.has_ended());
    const auto reason = pipeline.stream_error();
    ASSERT_TRUE(reason.has_value());
    EXPECT_TRUE(reason->starts_with("unplugged: ")) << *reason;
    EXPECT_GT(reason->size(), std::string_view("unplugged: ").size());
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, AStartThatFailsSaysWhy)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("filesrc", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(
      pipeline.create_pipeline_from_string("filesrc name=absent location=/kataglyphis/no/such/file ! appsink name=sink")
        .has_value());
    EXPECT_EQ(kataglyphis::test::error_of(pipeline.start()), gstreamer::GStreamerError::StateChangeFailed);
    const auto reason = pipeline.stream_error();
    ASSERT_TRUE(reason.has_value());
    EXPECT_TRUE(reason->starts_with("absent: ")) << *reason;
    EXPECT_FALSE(pipeline.is_playing());
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
    EXPECT_TRUE(frames.wait_for(3, kataglyphis::test::kStreamTimeout));
    EXPECT_TRUE(pipeline.stop().has_value());

    std::scoped_lock lock(seen_mutex);
    EXPECT_EQ(timestamps, (std::vector<std::uint64_t>{ 0, frame_start_30fps(1), frame_start_30fps(2) }));
}

// A pull can take the frame a callback was told about; the callback must not wait for another.
TEST(GStreamerPipeline, StopEndsWhenAPullTakesTheCallbacksFrame)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    std::promise<void> finished;
    auto done = finished.get_future();
    std::thread worker([&finished] {
        for (int round = 0; round < 20; ++round) {
            gstreamer::GStreamerPipeline pipeline;
            EXPECT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
            pipeline.set_buffer_callback([](const gstreamer::BufferInfo &) {});
            EXPECT_TRUE(pipeline.start().has_value());
            // Either consumer may win each frame; only the end of stop() is the contract.
            std::ignore = pipeline.pull_sample(static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count()));
            EXPECT_TRUE(pipeline.stop().has_value());
        }
        finished.set_value();
    });
    if (done.wait_for(std::chrono::seconds(120)) != std::future_status::ready) {
        ADD_FAILURE() << "stop() did not return";
        std::abort();
    }
    worker.join();
}

TEST(GStreamerPipeline, ACallbackSetBeforeThePipelineStillGetsFrames)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    EventCounter frames;
    pipeline.set_buffer_callback([&](const gstreamer::BufferInfo &) { frames.add(); });
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(frames.wait_for(3, kataglyphis::test::kStreamTimeout));
    EXPECT_TRUE(pipeline.stop().has_value());
    EXPECT_EQ(frames.count(), 3);
}

TEST(GStreamerPipeline, APipelineWithoutAnAppsinkHasNothingToPull)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("fakesrc", "fakesink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string("fakesrc num-buffers=1 ! fakesink").has_value());
    EXPECT_EQ(kataglyphis::test::error_of(pipeline.pull_sample(10)), gstreamer::GStreamerError::ElementCreationFailed);
}

TEST(GStreamerPipeline, PauseAndStartTrackTheState)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "fakesink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string("videotestsrc is-live=true ! fakesink").has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(pipeline.is_playing());

    ASSERT_TRUE(pipeline.pause().has_value());
    EXPECT_FALSE(pipeline.is_playing());

    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(pipeline.is_playing());

    ASSERT_TRUE(pipeline.stop().has_value());
    EXPECT_FALSE(pipeline.is_playing());
}

TEST(GStreamerPipeline, ReplacingThePipelineReleasesTheOldOne)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    ASSERT_TRUE(pipeline.start().has_value());
    ASSERT_TRUE(pipeline
        .create_pipeline_from_string("videotestsrc num-buffers=1 ! video/x-raw,format=GRAY8,width=4,height=1 "
                                     "! appsink name=sink sync=false")
        .has_value());
    // The new pipeline is idle; its appsink, not the old one, answers with the new frame size.
    EXPECT_FALSE(pipeline.is_playing());
    ASSERT_TRUE(pipeline.start().has_value());
    const auto sample = pipeline.pull_sample(static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count()));
    ASSERT_TRUE(sample.has_value());
    EXPECT_EQ(sample->size, 4U);
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(GStreamerPipeline, AMovedPipelineKeepsStreaming)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string(std::string(kThreeBlackFrames)).has_value());
    gstreamer::GStreamerPipeline moved(std::move(pipeline));
    ASSERT_TRUE(moved.start().has_value());
    EXPECT_TRUE(moved.pull_sample(static_cast<std::uint32_t>(kataglyphis::test::kStreamTimeout.count())).has_value());
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

TEST(GStreamerPipeline, QuotingEscapesTheQuoteAndTheBackslash)
{ EXPECT_EQ(gstreamer::quote_pipeline_value(R"(a "b" \c)"), R"("a \"b\" \\c")"); }

TEST(GStreamerPipeline, EveryInferenceBuilderKeepsAPathWithASeparatorInOneValue)
{
    const std::string model = "model ! fakesink name=injected.onnx";
    const std::string quoted_model = "model-path=\"" + model + "\" ! ";
    const std::string clip = "clip ! b.mp4";

    const auto from_file = gstreamer::inference_pipeline_description(clip, model);
    EXPECT_TRUE(from_file.contains("location=\"" + clip + "\" ! ")) << from_file;
    EXPECT_TRUE(from_file.contains(quoted_model)) << from_file;
    const auto from_device = gstreamer::inference_pipeline_description("/dev/video0 ! 1", model);
    EXPECT_TRUE(from_device.contains("device=\"/dev/video0 ! 1\" ! ")) << from_device;
    const auto from_uri = gstreamer::inference_pipeline_description("file:///a ! b.mp4", model);
    EXPECT_TRUE(from_uri.contains("uri=\"file:///a ! b.mp4\" ! ")) << from_uri;

    const auto video = gstreamer::video_inference_pipeline_description(clip, model, 64, 48);
    EXPECT_TRUE(video.contains("location=\"" + clip + "\" ! ")) << video;
    EXPECT_TRUE(video.contains(quoted_model)) << video;
    const auto video_uri = gstreamer::video_inference_pipeline_description("file:///a ! b.mp4", model, 64, 48);
    EXPECT_TRUE(video_uri.contains("uri=\"file:///a ! b.mp4\" ! ")) << video_uri;

    const auto camera = gstreamer::camera_inference_pipeline_description("/dev/video0 ! 1", model, 64, 48, 30);
    EXPECT_TRUE(camera.contains("device=\"/dev/video0 ! 1\" ! ")) << camera;
    EXPECT_TRUE(camera.contains(quoted_model)) << camera;
}

TEST(GStreamerError, EveryValueHasANameOfItsOwn)
{
    const auto names = kataglyphis::test::names_of<kataglyphis::gstreamer::GStreamerError>();
    ASSERT_EQ(names.size(), 10U);
    EXPECT_EQ(names.front(), "InitializationFailed");
    EXPECT_EQ(names.back(), "ResourceNotFound");
    EXPECT_TRUE(kataglyphis::test::all_differ(names));
    EXPECT_EQ(to_string(static_cast<kataglyphis::gstreamer::GStreamerError>(10)), "UnknownError");
}
