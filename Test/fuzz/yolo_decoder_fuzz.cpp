#include "kataglyphis_test_support.h"

#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

import kataglyphis.onnx_inference;
import kataglyphis.yolo_detector;

namespace detection = kataglyphis::detection;
using kataglyphis::test::YoloReshapeGeometry;

namespace {

// The reshape model makes each fuzz input the raw detector output: six rows of cx, cy, w, h, objectness, two classes.
constexpr YoloReshapeGeometry kGeometry{ 2, 7, 6, 7 };
constexpr float kThreshold = 0.25F;
// The frame both properties decode into.
constexpr detection::FrameMapping kFrame{ .frame_width = 14, .frame_height = 6 };

// Both corners on the frame; the far one is a float sum, so it may miss an edge by a rounding step.
auto lies_on_the_frame(const detection::BoundingBox &box) -> bool
{
    constexpr double kStep = 1e-5;
    const auto within = [](double value, double far) -> bool { return value >= -kStep && value <= far + kStep; };
    return box.x >= 0.0F && box.x <= static_cast<float>(kFrame.frame_width) && box.y >= 0.0F
           && box.y <= static_cast<float>(kFrame.frame_height)
           && within(static_cast<double>(box.x) + box.width, kFrame.frame_width)
           && within(static_cast<double>(box.y) + box.height, kFrame.frame_height);
}

auto detector() -> detection::YoloDetector &
{
    static const kataglyphis::test::TempFile model(
      "kataglyphis-yolo-fuzz", ".onnx", kataglyphis::test::yolo_reshape_model(kGeometry));
    static detection::YoloDetector instance = [] {
        detection::YoloDetector created;
        detection::YoloConfig config;
        config.model_path = model.path();
        config.input_width = static_cast<std::uint32_t>(kGeometry.width);
        config.input_height = static_cast<std::uint32_t>(kGeometry.height);
        config.num_classes = 2;
        config.confidence_threshold = kThreshold;
        EXPECT_TRUE(created.initialize(config).has_value());
        return created;
    }();
    return instance;
}

}// namespace

// Whatever a model emits, NaN and infinities included, the decoded boxes are well formed.
void DecodedBoxesAreWellFormed(const std::vector<float> &raw_output)
{
    const auto result = detector().detect(raw_output, kFrame.frame_width, kFrame.frame_height);
    ASSERT_TRUE(result.has_value());
    ASSERT_LE(result->boxes.size(), static_cast<std::size_t>(kGeometry.rows));
    for (std::size_t i = 0; i < result->boxes.size(); ++i) {
        const auto &box = result->boxes[i];
        EXPECT_TRUE(std::isfinite(box.confidence)) << i;
        EXPECT_GE(box.confidence, kThreshold) << i;
        EXPECT_FALSE(std::isnan(box.x) || std::isnan(box.y) || std::isnan(box.width) || std::isnan(box.height)) << i;
        EXPECT_TRUE(lies_on_the_frame(box)) << i;
        EXPECT_TRUE(box.class_id == 0 || box.class_id == 1) << box.class_id;
        EXPECT_EQ(box.class_name, detection::YoloDetector::get_coco_class_name(box.class_id));
        if (i > 0) { EXPECT_GE(result->boxes[i - 1].confidence, box.confidence) << i; }
    }
}
FUZZ_TEST(YoloDecoderFuzz, DecodedBoxesAreWellFormed)
  .WithDomains(fuzztest::VectorOf(fuzztest::Arbitrary<float>()).WithSize(kGeometry.elements()))
  .WithSeeds({ { std::vector<float>(kGeometry.elements(), 0.5F) },
    { std::vector<float>(kGeometry.elements(), std::numeric_limits<float>::quiet_NaN()) },
    { std::vector<float>(kGeometry.elements(), std::numeric_limits<float>::infinity()) } });

namespace {

constexpr std::array kDecodedLayouts{ detection::YoloOutputLayout::CenterObjectnessScores,
    detection::YoloOutputLayout::CornersScoreClass,
    detection::YoloOutputLayout::CenterScoresByAnchor };

// The shape rule written out independently of the decoder: what each layout can read without leaving the tensor.
auto readable(detection::YoloOutputLayout layout, const std::vector<std::size_t> &dims, int classes, std::size_t size)
  -> bool
{
    if (!(dims.size() == 2 || (dims.size() == 3 && dims[0] == 1))) { return false; }
    const auto rows = dims[dims.size() - 2];
    const auto columns = dims[dims.size() - 1];
    if (rows * columns != size) { return false; }
    switch (layout) {
    case detection::YoloOutputLayout::CenterObjectnessScores:
        return columns >= 5;
    case detection::YoloOutputLayout::CornersScoreClass:
        return columns >= 6;
    default:
        return rows == 4 + static_cast<std::size_t>(classes);
    }
}

}// namespace

// Any shape and contents: an unreadable shape is InvalidOutputShape, a readable one decodes to boxes on the frame.
void MismatchedShapesAreInvalidOutputShape(std::size_t layout_index,
  const std::vector<std::size_t> &dims,
  int classes,
  const std::vector<float> &data)
{
    detection::YoloConfig config;
    config.output_layout = kDecodedLayouts[layout_index];
    config.num_classes = classes;
    config.confidence_threshold = kThreshold;
    kataglyphis::inference::TensorData tensor{ data, { dims } };
    const auto result = detection::decode_detections(tensor, config, kFrame);
    if (!readable(config.output_layout, dims, classes, data.size())) {
        ASSERT_FALSE(result.has_value());
        EXPECT_EQ(result.error(), detection::OnnxError::InvalidOutputShape);
        return;
    }
    ASSERT_TRUE(result.has_value());
    for (std::size_t i = 0; i < result->size(); ++i) {
        const auto &box = (*result)[i];
        EXPECT_TRUE(std::isfinite(box.confidence) && box.confidence >= kThreshold) << i;
        EXPECT_GE(box.class_id, 0);
        EXPECT_LT(box.class_id, std::max(classes, 1));
        EXPECT_TRUE(lies_on_the_frame(box)) << i;
        if (i > 0) { EXPECT_GE((*result)[i - 1].confidence, box.confidence) << i; }
    }
}
FUZZ_TEST(YoloDecoderFuzz, MismatchedShapesAreInvalidOutputShape)
  .WithDomains(fuzztest::InRange<std::size_t>(0, kDecodedLayouts.size() - 1),
    fuzztest::VectorOf(fuzztest::InRange<std::size_t>(0, 9)).WithMaxSize(4),
    fuzztest::InRange(0, 5),
    fuzztest::VectorOf(fuzztest::Arbitrary<float>()).WithMaxSize(90))
  .WithSeeds({ { 2, { 1, 6, 3 }, 2, std::vector<float>(18, 0.9F) },
    { 2, { 1, 7, 3 }, 2, std::vector<float>(21, 0.9F) },
    { 1, { 1, 2, 6 }, 3, std::vector<float>(12, 0.5F) },
    { 0, { 2, 1, 7 }, 2, std::vector<float>(14, 0.5F) },
    // A corner row and a centre row that reach past every edge of the frame.
    { 1, { 1, 1, 6 }, 3, std::vector<float>{ -5.0F, -5.0F, 100.0F, 100.0F, 0.9F, 1.0F } },
    { 0, { 1, 1, 7 }, 2, std::vector<float>{ 7.0F, 3.0F, 100.0F, 100.0F, 0.9F, 0.9F, 0.1F } } });
