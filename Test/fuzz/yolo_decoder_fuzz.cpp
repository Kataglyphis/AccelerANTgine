#include "kataglyphis_test_support.h"

#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

import kataglyphis.yolo_detector;

namespace detection = kataglyphis::detection;
using kataglyphis::test::YoloReshapeGeometry;

namespace {

// The reshape model makes each fuzz input the raw detector output: six rows of cx, cy, w, h, objectness, two classes.
constexpr YoloReshapeGeometry kGeometry{ 2, 7, 6, 7 };
constexpr float kThreshold = 0.25F;

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
    const auto result = detector().detect(raw_output, 14, 6);
    ASSERT_TRUE(result.has_value());
    ASSERT_LE(result->boxes.size(), static_cast<std::size_t>(kGeometry.rows));
    for (std::size_t i = 0; i < result->boxes.size(); ++i) {
        const auto &box = result->boxes[i];
        EXPECT_TRUE(std::isfinite(box.confidence)) << i;
        EXPECT_GE(box.confidence, kThreshold) << i;
        EXPECT_FALSE(std::isnan(box.x) || std::isnan(box.y) || std::isnan(box.width) || std::isnan(box.height)) << i;
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
