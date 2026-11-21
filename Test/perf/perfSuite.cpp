#include "kataglyphis_test_support.h"

#include <benchmark/benchmark.h>

#ifdef __linux__
#include <csignal>
#include <execinfo.h>
#include <unistd.h>
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "kShippedInferenceConfig.inc"

import kataglyphis.config_loader;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.onnx_inference;
import kataglyphis.text_generation;
import kataglyphis.toml_config;
import kataglyphis.yolo_detector;

namespace inference = kataglyphis::inference;
namespace detection = kataglyphis::detection;
namespace gstreamer = kataglyphis::gstreamer;
namespace text = kataglyphis::text;
using kataglyphis::test::TempFile;
using kataglyphis::test::YoloReshapeGeometry;

namespace {

constexpr std::string_view kSettings =
  R"({"signalingServerUrl": "wss://example.test/webrtc-ws", "reconnectionTimeoutMs": 2500,
      "stunServers": ["stun:one.example:3478", "stun:two.example:3478"], "turnServers": ["turn:relay.example:3478"],
      "video": {"defaultWidth": 1920, "defaultHeight": 1080, "defaultFramerate": 60, "defaultBitrateKbps": 8000},
      "texture": {"width": 800, "height": 600}, "android": {"width": 640, "height": 360, "fps": 24},
      "stream": {"source": "v4l2", "encoder": "vp8", "device": "/dev/video4", "producerId": "producer-7"}})";

#ifdef __linux__
// A suite that dies on a signal in CI leaves no core and the image has no gdb: the stack goes to stderr instead.
void print_stack_and_die(int signal_number)
{
    constexpr int kFrames = 64;
    std::array<void *, kFrames> frames{};
    const int depth = backtrace(frames.data(), kFrames);
    backtrace_symbols_fd(frames.data(), depth, STDERR_FILENO);
    (void)std::signal(signal_number, SIG_DFL);
    (void)std::raise(signal_number);
}

const bool kStackOnCrash = [] -> bool {
    (void)std::signal(SIGSEGV, print_stack_and_die);
    (void)std::signal(SIGBUS, print_stack_and_die);
    (void)std::signal(SIGABRT, print_stack_and_die);
    return true;
}();
#endif

// YOLOv5-style output, 1680 rows of 4 box values, objectness and 80 class scores.
constexpr YoloReshapeGeometry kYoloGeometry{ 560, 85, 1680, 85 };

auto float_input(std::size_t elements) -> std::vector<float>
{
    std::vector<float> data(elements);
    for (std::size_t i = 0; i < elements; ++i) { data[i] = static_cast<float>(i % 17) - 8.0F; }
    return data;
}

// The first `candidates` rows are confident, disjoint boxes of one class, the worst case for NMS's pairwise loop.
auto yolo_output(std::size_t candidates) -> std::vector<float>
{
    std::vector<float> rows(kYoloGeometry.elements(), 0.0F);
    const auto values = static_cast<std::size_t>(kYoloGeometry.values_per_row);
    for (std::size_t row = 0; row < candidates; ++row) {
        float *values_of_row = rows.data() + row * values;
        values_of_row[0] = static_cast<float>(row % 40) * 16.0F + 8.0F;
        values_of_row[1] = static_cast<float>(row / 40) * 16.0F + 8.0F;
        values_of_row[2] = 10.0F;
        values_of_row[3] = 10.0F;
        values_of_row[4] = 0.9F;
        values_of_row[5] = 0.9F;
    }
    return rows;
}

// Set when a required input failed; main then exits 1, so a gated benchmark cannot drop out of results.json.
std::atomic<bool> required_input_failed{ false };

// KATAGLYPHIS_REQUIRE_MODEL=1 (the Linux lanes) turns a missing model or GenAI into a failed run instead of a skip.
auto skip_or_fail(benchmark::State &state, const char *reason) -> void
{
    const char *require = std::getenv("KATAGLYPHIS_REQUIRE_MODEL");
    if (require != nullptr && std::string_view(require) == "1") { required_input_failed = true; }
    state.SkipWithError(reason);
}

// SkipWithError alone still exits 0: a benchmark that fails once its inputs are there fails the suite (BB's rule).
std::atomic<int> failed_benchmarks{ 0 };

auto fail_benchmark(benchmark::State &state, const char *reason) -> void
{
    ++failed_benchmarks;
    state.SkipWithError(reason);
}

// KATAGLYPHIS_DETECTOR_MODEL, else the configure-time models/ path, else the copy a staged suite carries beside it.
auto detector_model() -> std::filesystem::path
{
    const char *model = std::getenv("KATAGLYPHIS_DETECTOR_MODEL");
    if (model != nullptr && *model != '\0') { return model; }
    const std::filesystem::path built{ KATAGLYPHIS_DETECTOR_MODEL };
    if (std::filesystem::exists(built)) { return built; }
    return kataglyphis::test::executable_dir() / "models" / built.filename();
}

// One intra-op and one inter-op thread, so a cachegrind instruction count repeats across runs.
auto detector_config() -> detection::YoloConfig
{
    detection::YoloConfig config;
    config.model_path = detector_model();
    config.output_layout = detection::YoloOutputLayout::CornersScoreClass;
    config.intra_op_num_threads = 1;
    config.inter_op_num_threads = 1;
    return config;
}

// A 1280x720 RGB frame of fixed pseudo-random bytes: the detector's decoded camera frame, minus GStreamer.
auto synthetic_frame() -> gstreamer::BufferInfo
{
    constexpr std::uint32_t kWidth = 1280;
    constexpr std::uint32_t kHeight = 720;
    gstreamer::BufferInfo frame;
    frame.size = static_cast<std::size_t>(kWidth) * kHeight * 3;
    frame.data.resize(frame.size);
    for (std::size_t i = 0; i < frame.size; ++i) { frame.data[i] = static_cast<std::byte>((i * 7U) % 251U); }
    frame.metadata.width = kWidth;
    frame.metadata.height = kHeight;
    frame.metadata.format = "RGB";
    return frame;
}

}// namespace

static void BM_ParseWebRtcSettings(benchmark::State &state)
{
    const std::string json(kSettings);
    for (auto _ : state) {
        auto config = kataglyphis::config::parse_webrtc_config(json);
        benchmark::DoNotOptimize(config);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations() * json.size()));
}
BENCHMARK(BM_ParseWebRtcSettings);

static void BM_ParseShippedInferenceConfig(benchmark::State &state)
{
    const std::string toml(kShippedInferenceConfig);
    for (auto _ : state) {
        auto config = kataglyphis::config::parse_inference_config(toml);
        benchmark::DoNotOptimize(config);
    }
    state.SetBytesProcessed(static_cast<std::int64_t>(state.iterations() * toml.size()));
}
BENCHMARK(BM_ParseShippedInferenceConfig);

// One Relu node over a 1 x elements tensor, X to Y.
namespace {
auto relu_model(std::int64_t elements)
{
    return kataglyphis::test::build_onnx_model(
      { { "X", { 1, elements } } }, { { "Y", { 1, elements } } }, { { "Relu", { "X" }, { "Y" } } });
}
}// namespace

// The engine's per-call overhead around ORT: the input copy, tensor wrapping and the output copy.
static void BM_OnnxRunInference(benchmark::State &state)
{
    const auto elements = static_cast<std::int64_t>(state.range(0));
    const TempFile model("kataglyphis-bench-relu", ".onnx", relu_model(elements));
    inference::OnnxInferenceEngine engine;
    auto config = inference::create_default_session_config(model.path());
    config.intra_op_num_threads = 1;
    config.inter_op_num_threads = 1;
    if (!engine.initialize(config)) {
        fail_benchmark(state, "ONNX Runtime could not load the generated model");
        return;
    }
    const auto input = float_input(static_cast<std::size_t>(elements));
    const inference::TensorShape shape{ { 1, static_cast<std::size_t>(elements) } };
    for (auto _ : state) {
        auto result = engine.run_inference(input, shape, "X");
        benchmark::DoNotOptimize(result);
    }
    state.SetBytesProcessed(
      static_cast<std::int64_t>(state.iterations()) * elements * static_cast<std::int64_t>(sizeof(float)));
}
BENCHMARK(BM_OnnxRunInference)->Arg(1024)->Arg(1 << 16)->Arg(3 * 640 * 640);

// The detector's call: one 3x640x640 frame on the caller's buffer, without the input copy.
namespace {
void BM_OnnxRunInferenceInPlace(benchmark::State &state)
{
    constexpr std::int64_t elements = std::int64_t{ 3 } * 640 * 640;
    const TempFile model("kataglyphis-bench-relu-in-place", ".onnx", relu_model(elements));
    inference::OnnxInferenceEngine engine;
    auto config = inference::create_default_session_config(model.path());
    config.intra_op_num_threads = 1;
    config.inter_op_num_threads = 1;
    if (!engine.initialize(config)) {
        fail_benchmark(state, "ONNX Runtime could not load the generated model");
        return;
    }
    auto input = float_input(static_cast<std::size_t>(elements));
    const inference::TensorShape shape{ { 1, static_cast<std::size_t>(elements) } };
    for ([[maybe_unused]] const auto iteration : state) {
        auto result = engine.run_inference_in_place(input, shape, "X");
        if (!result) {
            fail_benchmark(state, "run_inference_in_place failed");
            break;
        }
        benchmark::DoNotOptimize(result);
    }
    state.SetBytesProcessed(
      static_cast<std::int64_t>(state.iterations()) * elements * static_cast<std::int64_t>(sizeof(float)));
}
}// namespace
BENCHMARK(BM_OnnxRunInferenceInPlace);

// Detection end to end on a YOLOv5-sized output: inference, decoding and NMS over `candidates` confident boxes.
static void BM_YoloDetect(benchmark::State &state)
{
    const TempFile model("kataglyphis-bench-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kYoloGeometry));
    detection::YoloDetector detector;
    detection::YoloConfig config;
    config.model_path = model.path();
    config.input_width = static_cast<std::uint32_t>(kYoloGeometry.width);
    config.input_height = static_cast<std::uint32_t>(kYoloGeometry.height);
    if (!detector.initialize(config)) {
        fail_benchmark(state, "ONNX Runtime could not load the generated model");
        return;
    }
    const auto rows = yolo_output(static_cast<std::size_t>(state.range(0)));
    std::size_t boxes = 0;
    for (auto _ : state) {
        auto result = detector.detect(rows, 1280, 720);
        boxes = result ? result->boxes.size() : 0;
        benchmark::DoNotOptimize(result);
    }
    state.counters["boxes"] = static_cast<double>(boxes);
}
BENCHMARK(BM_YoloDetect)->Arg(0)->Arg(64)->Arg(512);

// The frame path's copy out of GStreamer: one pulled 640x480 RGB frame per iteration.
static void BM_GStreamerPullSample(benchmark::State &state)
{
    if (!gstreamer::GStreamerPipeline::initialize_gstreamer()) {
        state.SkipWithMessage("gst_init failed");
        return;
    }
    gstreamer::GStreamerPipeline pipeline;
    if (!pipeline.create_pipeline_from_string(
          "videotestsrc pattern=black ! video/x-raw,format=RGB,width=640,height=480,framerate=30/1 "
          "! appsink name=sink sync=false max-buffers=4")
        || !pipeline.start()) {
        state.SkipWithMessage("videotestsrc, capsfilter or appsink is not installed here");
        return;
    }
    std::size_t bytes = 0;
    for (auto _ : state) {
        auto sample = pipeline.pull_sample(5000);
        if (!sample) {
            fail_benchmark(state, "the pipeline stopped delivering frames");
            break;
        }
        bytes += sample->size;
        benchmark::DoNotOptimize(sample);
    }
    (void)pipeline.stop();
    state.SetBytesProcessed(static_cast<std::int64_t>(bytes));
}
BENCHMARK(BM_GStreamerPullSample);

// The detector's per-frame CPU work before ORT: scaling a 1280x720 RGB frame into the 640x640 planar input.
static void BM_PreprocessFrame(benchmark::State &state)
{
    const auto frame = synthetic_frame();
    for (auto _ : state) {
        auto input = detection::preprocess_frame(frame, 640, 640);
        if (!input) {
            fail_benchmark(state, "preprocess_frame refused the synthetic frame");
            break;
        }
        benchmark::DoNotOptimize(input);
    }
}
BENCHMARK(BM_PreprocessFrame);

// The same into one kept buffer, as the video pipeline runs it: no allocation, and no fill before a stretch.
static void BM_PreprocessFrameInto(benchmark::State &state)
{
    const auto frame = synthetic_frame();
    detection::PreprocessedFrame input;
    for (auto _ : state) {
        if (!detection::preprocess_frame_into(frame, 640, 640, detection::FramePreprocessMode::Stretch, input)) {
            fail_benchmark(state, "preprocess_frame_into refused the synthetic frame");
            break;
        }
        benchmark::DoNotOptimize(input.data.data());
    }
}
BENCHMARK(BM_PreprocessFrameInto);

// One frame through the shipped DEIM detector on the CPU: preprocess, inference and decoding.
static void BM_DetectFrame(benchmark::State &state)
{
    detection::YoloDetector detector;
    if (!detector.initialize(detector_config())) {
        skip_or_fail(state, "the DEIM model is missing or ONNX Runtime could not load it");
        return;
    }
    const auto frame = synthetic_frame();
    for (auto _ : state) {
        auto result = detector.detect_frame(frame);
        if (!result) {
            fail_benchmark(state, "detect_frame failed");
            break;
        }
        benchmark::DoNotOptimize(result);
    }
}
BENCHMARK(BM_DetectFrame)->Unit(benchmark::kMillisecond);

// Whether the detector keeps up with a live 30 fps camera: the frames it ran on per second and the share it dropped.
namespace {
void BM_VideoPipelineKeepsUp(benchmark::State &state)
{
    constexpr std::uint32_t width = 640;
    constexpr std::uint32_t height = 480;
    constexpr std::uint32_t fps = 30;
    constexpr auto run_for = std::chrono::seconds(2);
    detection::VideoDetectionConfig config;
    config.yolo_config = detector_config();
    config.gstreamer_config.pipeline_description =
      "videotestsrc is-live=true ! " + detection::camera_detection_pipeline_tail(width, height, fps);
    std::uint64_t frames = 0;
    std::uint64_t dropped = 0;
    // Between the first frame and the last, so the model's load before them does not dilute the rate.
    double seconds = 0.0;
    for ([[maybe_unused]] const auto iteration : state) {
        detection::VideoDetectorPipeline pipeline;
        if (!pipeline.initialize(config) || !pipeline.start()) {
            skip_or_fail(state, "the DEIM model, videotestsrc or ONNX Runtime is missing");
            return;
        }
        std::this_thread::sleep_for(run_for);
        if (!pipeline.stop()) {
            fail_benchmark(state, "the pipeline did not stop");
            return;
        }
        const auto stats = pipeline.stats();
        constexpr double nanoseconds_per_second = 1e9;
        if (stats.frames > 1) {
            frames += stats.frames - 1;
            seconds += static_cast<double>(stats.last_timestamp_ns - stats.first_timestamp_ns) / nanoseconds_per_second;
        }
        dropped += stats.dropped;
    }
    state.counters["frames_per_second"] = seconds > 0.0 ? static_cast<double>(frames) / seconds : 0.0;
    state.counters["dropped_share"] =
      frames + dropped == 0 ? 0.0 : static_cast<double>(dropped) / static_cast<double>(frames + dropped);
}
}// namespace
BENCHMARK(BM_VideoPipelineKeepsUp)->Unit(benchmark::kMillisecond)->Iterations(1)->UseRealTime();

// Loading the DEIM model into a fresh ORT session, the cost a CLI start pays once.
static void BM_SessionCreate(benchmark::State &state)
{
    const auto config = detector_config();
    for (auto _ : state) {
        detection::YoloDetector detector;
        if (!detector.initialize(config)) {
            skip_or_fail(state, "the DEIM model is missing or ONNX Runtime could not load it");
            break;
        }
        benchmark::DoNotOptimize(detector);
    }
}
BENCHMARK(BM_SessionCreate)->Unit(benchmark::kMillisecond);

// Sixteen greedy tokens from the hub's tiny GenAI model: the text path's overhead around the chain GenAI.
static void BM_TextGenerateTiny(benchmark::State &state)
{
    text::TextGenerator generator;
    if (!generator.initialize(kataglyphis::test::tiny_genai_model_dir())) {
        skip_or_fail(state, "the chain GenAI could not load the tiny test model");
        return;
    }
    const std::vector<text::ChatMessage> messages{ { "user", "abc" } };
    text::GenerationOptions options;
    options.max_new_tokens = 16;
    std::size_t tokens = 0;
    for (auto _ : state) {
        auto result = generator.generate(messages, options);
        if (!result) {
            fail_benchmark(state, "generate failed");
            break;
        }
        tokens += result->tokens.size();
        benchmark::DoNotOptimize(result);
    }
    state.counters["tokens_per_second"] = benchmark::Counter(static_cast<double>(tokens), benchmark::Counter::kIsRate);
}
BENCHMARK(BM_TextGenerateTiny)->Unit(benchmark::kMillisecond);

auto main(int argc, char **argv) -> int
{
    benchmark::Initialize(&argc, argv);
    if (benchmark::ReportUnrecognizedArguments(argc, argv)) { return 1; }
    benchmark::RunSpecifiedBenchmarks();
    benchmark::Shutdown();
    if (failed_benchmarks > 0) {
        std::fprintf(stderr, "%d benchmark(s) failed: see ERROR OCCURRED\n", failed_benchmarks.load());
    }
    return required_input_failed || failed_benchmarks > 0 ? 1 : 0;
}
