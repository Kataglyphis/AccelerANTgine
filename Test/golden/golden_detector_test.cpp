// The locked model on ModelANT's two_cats.jpg against a recorded demo run; not covered: GPU providers, other images.
#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

#include <dlfcn.h>

import nlohmann.json;
import kataglyphis.onnx_inference;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.yolo_detector;

namespace detection = kataglyphis::detection;
namespace gstreamer = kataglyphis::gstreamer;
namespace inference = kataglyphis::inference;

namespace {

constexpr int kCat = 15;
constexpr float kMinIou = 0.9F;
constexpr float kMaxScoreDelta = 0.05F;
// Corners are compared as fractions of the frame, so every value is on the scores' 0..1 scale.
constexpr float kProviderTolerance = 1e-4F;

auto decoded_photo() -> gstreamer::BufferInfo
{
    static const gstreamer::BufferInfo frame = [] {
        EXPECT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
        std::ostringstream location;
        location << '"' << KATAGLYPHIS_GOLDEN_IMAGE << '"';
        gstreamer::PipelineConfig config;
        config.pipeline_description =
          "filesrc location=" + location.str()
          + " ! jpegdec ! videoconvert ! video/x-raw,format=RGB ! appsink name=sink sync=false";
        gstreamer::GStreamerPipeline pipeline;
        EXPECT_TRUE(pipeline.create_pipeline(config).has_value());
        EXPECT_TRUE(pipeline.start().has_value());
        auto sample = pipeline.pull_sample(10000);
        EXPECT_TRUE(pipeline.stop().has_value());
        EXPECT_TRUE(sample.has_value());
        return sample ? std::move(*sample) : gstreamer::BufferInfo{};
    }();
    return frame;
}

auto auto_config(inference::ExecutionProvider provider = inference::ExecutionProvider::Cpu) -> detection::YoloConfig
{
    detection::YoloConfig config;
    config.model_path = KATAGLYPHIS_GOLDEN_MODEL;
    config.output_layout = detection::YoloOutputLayout::Auto;
    config.execution_provider = provider;
    return config;
}

struct Box
{ float x1, y1, x2, y2, score; };

auto iou(const Box &a, const Box &b) -> float
{
    const float w = std::min(a.x2, b.x2) - std::max(a.x1, b.x1);
    const float h = std::min(a.y2, b.y2) - std::max(a.y1, b.y1);
    if (w <= 0 || h <= 0) { return 0.0F; }
    const float inter = w * h;
    return inter / (((a.x2 - a.x1) * (a.y2 - a.y1)) + ((b.x2 - b.x1) * (b.y2 - b.y1)) - inter);
}

auto recorded_cats() -> std::vector<Box>
{
    std::ifstream file(KATAGLYPHIS_GOLDEN_JSON);
    const auto golden = nlohmann::json::parse(file, nullptr, false);
    EXPECT_FALSE(golden.is_discarded());
    std::vector<Box> cats;
    for (const auto &entry : golden["detections"]) {
        if (entry["class"].get<int>() != kCat) { continue; }
        const auto &b = entry["box"];
        cats.push_back(
          { b[0].get<float>(), b[1].get<float>(), b[2].get<float>(), b[3].get<float>(), entry["score"].get<float>() });
    }
    return cats;
}

auto initialized(detection::YoloDetector &detector, const detection::YoloConfig &config) -> bool
{
    const auto result = detector.initialize(config);
    EXPECT_TRUE(result.has_value()) << static_cast<int>(result.error_or(detection::OnnxError::InferenceFailed));
    return result.has_value();
}

// Stops at a tenth: lower scores sit among near ties, where providers may order the model's top-k differently.
auto detections(inference::ExecutionProvider provider, detection::YoloDetector &detector) -> std::vector<float>
{
    auto config = auto_config(provider);
    config.confidence_threshold = 0.1F;
    if (!detector.initialize(config)) { return {}; }
    const auto &photo = decoded_photo();
    const auto result = detector.detect_frame(photo);
    EXPECT_TRUE(result.has_value());
    std::vector<float> values;
    const auto w = static_cast<float>(photo.metadata.width);
    const auto h = static_cast<float>(photo.metadata.height);
    for (const auto &b : result->boxes) {
        values.insert(values.end(),
          { static_cast<float>(b.class_id),
            b.confidence,
            b.x / w,
            b.y / h,
            (b.x + b.width) / w,
            (b.y + b.height) / h });
    }
    return values;
}

auto max_difference(const std::vector<float> &a, const std::vector<float> &b) -> float
{
    EXPECT_EQ(a.size(), b.size());
    float worst = 0.0F;
    for (std::size_t i = 0; i < std::min(a.size(), b.size()); ++i) { worst = std::max(worst, std::abs(a[i] - b[i])); }
    return worst;
}

}// namespace

TEST(Golden, TwoCatsMatchTheRecordedRun)
{
    detection::YoloDetector detector;
    ASSERT_TRUE(initialized(detector, auto_config()));
    EXPECT_EQ(detector.output_layout(), detection::YoloOutputLayout::CornersScoreClass);
    const auto result = detector.detect_frame(decoded_photo());
    ASSERT_TRUE(result.has_value());
    std::vector<Box> cats;
    for (const auto &b : result->boxes) {
        if (b.class_id == kCat) { cats.push_back({ b.x, b.y, b.x + b.width, b.y + b.height, b.confidence }); }
        if (b.class_id == kCat) { EXPECT_EQ(b.class_name, "cat"); }
    }
    const auto golden = recorded_cats();
    ASSERT_GE(golden.size(), 2U);
    ASSERT_EQ(cats.size(), golden.size());
    for (const auto &expected : golden) {
        const auto best = std::ranges::max_element(
          cats, [&](const Box &a, const Box &b) { return iou(a, expected) < iou(b, expected); });
        EXPECT_GE(iou(*best, expected), kMinIou) << expected.x1 << "," << expected.y1;
        EXPECT_LE(std::abs(best->score - expected.score), kMaxScoreDelta) << expected.score;
        std::cout << "golden cat: IoU " << iou(*best, expected) << ", score " << best->score << " (recorded "
                  << expected.score << ")\n";
    }
}

TEST(Golden, ABlackFrameHasNoBoxes)
{
    detection::YoloDetector detector;
    ASSERT_TRUE(initialized(detector, auto_config()));
    gstreamer::BufferInfo black;
    black.metadata.width = 640;
    black.metadata.height = 480;
    black.metadata.format = "RGB";
    black.size = 640 * 480 * 3;
    black.data.assign(black.size, std::byte{ 0 });
    const auto result = detector.detect_frame(black);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->boxes.empty()) << result->boxes.size() << " boxes, first class " << result->boxes[0].class_id;
}

TEST(Golden, XnnpackMatchesCpu)
{
    ASSERT_TRUE(inference::provider_available(inference::ExecutionProvider::Xnnpack));
    detection::YoloDetector cpu_detector;
    detection::YoloDetector xnnpack_detector;
    const auto cpu = detections(inference::ExecutionProvider::Cpu, cpu_detector);
    const auto xnnpack = detections(inference::ExecutionProvider::Xnnpack, xnnpack_detector);
    ASSERT_TRUE(xnnpack_detector.is_initialized());
    ASSERT_GE(cpu.size(), 6U * 4U);
    const float worst = max_difference(cpu, xnnpack);
    std::cout << "XNNPACK vs CPU: max difference " << worst << " over " << cpu.size() / 6 << " boxes\n";
    EXPECT_LE(worst, kProviderTolerance);
}

// DNNL needs libdnnl beside its provider library; without it the request is refused, never run on plain CPU.
TEST(Golden, DnnlMatchesCpuOrIsProviderUnavailable)
{
    void *dnnl = dlopen("libdnnl.so.3", RTLD_NOW | RTLD_LOCAL);
    if (dnnl != nullptr) { dlclose(dnnl); }
    const bool loadable = inference::provider_available(inference::ExecutionProvider::Dnnl) && dnnl != nullptr;
    detection::YoloDetector cpu_detector;
    const auto cpu = detections(inference::ExecutionProvider::Cpu, cpu_detector);
    detection::YoloDetector dnnl_detector;
    const auto refused = dnnl_detector.initialize(auto_config(inference::ExecutionProvider::Dnnl));
    if (!loadable) {
        ASSERT_FALSE(refused.has_value());
        EXPECT_EQ(refused.error(), detection::OnnxError::ProviderUnavailable);
        std::cout << "DNNL: ProviderUnavailable\n";
        return;
    }
    ASSERT_TRUE(refused.has_value());
    const auto onednn = detections(inference::ExecutionProvider::Dnnl, dnnl_detector);
    const float worst = max_difference(cpu, onednn);
    std::cout << "DNNL vs CPU: max difference " << worst << " over " << cpu.size() / 6 << " boxes\n";
    EXPECT_LE(worst, kProviderTolerance);
}
