#include "kataglyphis_test_support.h"

#include <benchmark/benchmark.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "kShippedInferenceConfig.inc"

import kataglyphis.config_loader;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.onnx_inference;
import kataglyphis.toml_config;
import kataglyphis.yolo_detector;

namespace inference = kataglyphis::inference;
namespace detection = kataglyphis::detection;
namespace gstreamer = kataglyphis::gstreamer;
using kataglyphis::test::TempFile;
using kataglyphis::test::YoloReshapeGeometry;

namespace {

constexpr std::string_view kSettings =
  R"({"signalingServerUrl": "wss://example.test/webrtc-ws", "reconnectionTimeoutMs": 2500,
      "stunServers": ["stun:one.example:3478", "stun:two.example:3478"], "turnServers": ["turn:relay.example:3478"],
      "video": {"defaultWidth": 1920, "defaultHeight": 1080, "defaultFramerate": 60, "defaultBitrateKbps": 8000},
      "texture": {"width": 800, "height": 600}, "android": {"width": 640, "height": 360, "fps": 24},
      "stream": {"source": "v4l2", "encoder": "vp8", "device": "/dev/video4", "producerId": "producer-7"}})";

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

// The engine's per-call overhead around ORT: the input copy, tensor wrapping and the output copy.
static void BM_OnnxRunInference(benchmark::State &state)
{
    const auto elements = static_cast<std::int64_t>(state.range(0));
    const TempFile model("kataglyphis-bench-relu",
      ".onnx",
      kataglyphis::test::build_onnx_model(
        { { "X", { 1, elements } } }, { { "Y", { 1, elements } } }, { { "Relu", { "X" }, { "Y" } } }));
    inference::OnnxInferenceEngine engine;
    auto config = inference::create_default_session_config(model.path());
    config.intra_op_num_threads = 1;
    config.inter_op_num_threads = 1;
    if (!engine.initialize(config)) {
        state.SkipWithError("ONNX Runtime could not load the generated model");
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
        state.SkipWithError("ONNX Runtime could not load the generated model");
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
            state.SkipWithError("the pipeline stopped delivering frames");
            break;
        }
        bytes += sample->size;
        benchmark::DoNotOptimize(sample);
    }
    (void)pipeline.stop();
    state.SetBytesProcessed(static_cast<std::int64_t>(bytes));
}
BENCHMARK(BM_GStreamerPullSample);

BENCHMARK_MAIN();
