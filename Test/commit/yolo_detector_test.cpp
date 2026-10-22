#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "kInferenceContract.inc"
#include "kShippedInferenceConfig.inc"

import nlohmann.json;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.toml_config;
import kataglyphis.yolo_detector;

#include "gstreamer_test_support.h"

namespace detection = kataglyphis::detection;
namespace gstreamer = kataglyphis::gstreamer;
using kataglyphis::test::TempFile;
using kataglyphis::test::YoloReshapeGeometry;

namespace {

// Two classes, so a row is cx, cy, w, h, objectness, person, bicycle: six rows of seven values.
constexpr YoloReshapeGeometry kTwoClasses{ 2, 7, 6, 7 };

struct Row
{ float cx, cy, w, h, objectness, person, bicycle; };

auto flatten(std::initializer_list<Row> rows) -> std::vector<float>
{
    std::vector<float> data;
    for (const auto &row : rows) {
        data.insert(data.end(), { row.cx, row.cy, row.w, row.h, row.objectness, row.person, row.bicycle });
    }
    return data;
}

struct Corner
{ float x1, y1, x2, y2, score, class_index; };

auto flatten_corners(std::initializer_list<Corner> rows) -> std::vector<float>
{
    std::vector<float> data;
    for (const auto &row : rows) {
        data.insert(data.end(), { row.x1, row.y1, row.x2, row.y2, row.score, row.class_index });
    }
    return data;
}

auto two_class_config(const TempFile &model) -> detection::YoloConfig
{
    detection::YoloConfig config;
    config.model_path = model.path();
    config.input_width = static_cast<std::uint32_t>(kTwoClasses.width);
    config.input_height = static_cast<std::uint32_t>(kTwoClasses.height);
    config.num_classes = 2;
    config.confidence_threshold = 0.5F;
    config.nms_threshold = 0.45F;
    return config;
}

}// namespace

TEST(YoloDetector, CocoClassNamesCoverTheEightyClasses)
{
    EXPECT_EQ(detection::YoloDetector::get_coco_class_name(0), "person");
    EXPECT_EQ(detection::YoloDetector::get_coco_class_name(15), "cat");
    EXPECT_EQ(detection::YoloDetector::get_coco_class_name(16), "dog");
    EXPECT_EQ(detection::YoloDetector::get_coco_class_name(79), "toothbrush");
    for (const int outside : { -1, 80, 1000, INT_MIN, INT_MAX }) {
        EXPECT_EQ(detection::YoloDetector::get_coco_class_name(outside), "unknown") << outside;
    }
}

TEST(YoloDetector, TheShippedConfigLabelsMatchTheClassTable)
{
    const auto config = kataglyphis::config::parse_inference_config(std::string(kShippedInferenceConfig));
    ASSERT_TRUE(config.has_value());
    ASSERT_EQ(config->model.labels.size(), 80U);
    for (std::size_t i = 0; i < config->model.labels.size(); ++i) {
        EXPECT_EQ(config->model.labels[i], detection::YoloDetector::get_coco_class_name(static_cast<int>(i))) << i;
    }
}

TEST(YoloDetector, DetectBeforeInitializeFails)
{
    detection::YoloDetector detector;
    EXPECT_FALSE(detector.is_initialized());
    const std::vector<float> image(3 * 640 * 640, 0.0F);
    const auto result = detector.detect(image, 640, 640);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), detection::OnnxError::SessionNotInitialized);
}

TEST(YoloDetector, AMissingModelIsModelLoadFailed)
{
    detection::YoloDetector detector;
    detection::YoloConfig config;
    config.model_path = kataglyphis::test::missing_path("yolo.onnx");
    const auto result = detector.initialize(config);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), detection::OnnxError::ModelLoadFailed);
    EXPECT_FALSE(detector.is_initialized());
}

TEST(YoloDetector, DecodesThresholdsClassesNmsAndScale)
{
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());
    ASSERT_TRUE(detector.is_initialized());

    const auto rows = flatten({
      { 10, 10, 4, 4, 0.9F, 0.9F, 0.1F },// person 0.81: kept
      { 10.5F, 10, 4, 4, 0.8F, 0.9F, 0.1F },// person 0.72 overlapping the first: suppressed
      { 10, 10, 4, 4, 0.9F, 0.2F, 0.8F },// bicycle 0.72 on the same box: kept, another class
      { 40, 30, 2, 2, 0.4F, 1.0F, 0.0F },// objectness under the threshold: dropped
      { 40, 30, 2, 2, 0.9F, 0.3F, 0.2F },// best class too weak, 0.27: dropped
      { 30, 5, 6, 2, 0.7F, 0.95F, 0.0F },// person 0.665, disjoint: kept
    });

    // The frame is twice as wide and three times as tall as the model input.
    const auto result = detector.detect(rows, 14, 6);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->original_width, 14U);
    EXPECT_EQ(result->original_height, 6U);
    ASSERT_EQ(result->boxes.size(), 3U);

    const auto &first = result->boxes[0];
    EXPECT_EQ(first.class_id, 0);
    EXPECT_EQ(first.class_name, "person");
    EXPECT_NEAR(first.confidence, 0.81F, 1e-5F);
    EXPECT_FLOAT_EQ(first.x, (10.0F - 2.0F) * 2.0F);
    EXPECT_FLOAT_EQ(first.y, (10.0F - 2.0F) * 3.0F);
    EXPECT_FLOAT_EQ(first.width, 8.0F);
    EXPECT_FLOAT_EQ(first.height, 12.0F);

    EXPECT_EQ(result->boxes[1].class_name, "bicycle");
    EXPECT_NEAR(result->boxes[1].confidence, 0.72F, 1e-5F);
    EXPECT_EQ(result->boxes[2].class_name, "person");
    EXPECT_NEAR(result->boxes[2].confidence, 0.665F, 1e-5F);
    EXPECT_FLOAT_EQ(result->boxes[2].x, (30.0F - 3.0F) * 2.0F);
}

TEST(YoloDetector, BoxesComeBackSortedByConfidence)
{
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());
    const auto rows = flatten({
      { 1, 1, 1, 1, 0.6F, 0.9F, 0 },
      { 10, 1, 1, 1, 0.9F, 0.9F, 0 },
      { 20, 1, 1, 1, 0.7F, 0.9F, 0 },
      { 30, 1, 1, 1, 1.0F, 0.9F, 0 },
      { 40, 1, 1, 1, 0.8F, 0.9F, 0 },
      { 50, 1, 1, 1, 0.65F, 0.9F, 0 },
    });
    const auto result = detector.detect(rows, 7, 2);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->boxes.size(), 6U);
    for (std::size_t i = 1; i < result->boxes.size(); ++i) {
        EXPECT_GE(result->boxes[i - 1].confidence, result->boxes[i].confidence);
    }
}

TEST(YoloDetector, FiveValueRowsUseTheObjectnessAsConfidence)
{
    constexpr YoloReshapeGeometry kNoClasses{ 2, 5, 6, 5 };
    const TempFile model("kataglyphis-yolo5", ".onnx", kataglyphis::test::yolo_reshape_model(kNoClasses));
    detection::YoloDetector detector;
    detection::YoloConfig config;
    config.model_path = model.path();
    config.input_width = 5;
    config.input_height = 2;
    config.confidence_threshold = 0.5F;
    ASSERT_TRUE(detector.initialize(config).has_value());

    std::vector<float> rows(kNoClasses.elements(), 0.0F);
    const std::vector<float> only_row{ 2, 2, 2, 2, 0.6F };
    std::copy(only_row.begin(), only_row.end(), rows.begin());
    const auto result = detector.detect(rows, 5, 2);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->boxes.size(), 1U);
    EXPECT_FLOAT_EQ(result->boxes[0].confidence, 0.6F);
    EXPECT_EQ(result->boxes[0].class_id, 0);
}

TEST(YoloDetector, CornerRowsDecodeScoreClassAndScale)
{
    // x1, y1, x2, y2, score, class: the DEIM and YOLOv10 layout, six rows of six values.
    constexpr YoloReshapeGeometry kCorners{ 2, 6, 6, 6 };
    const TempFile model("kataglyphis-corners", ".onnx", kataglyphis::test::yolo_reshape_model(kCorners));
    detection::YoloDetector detector;
    detection::YoloConfig config;
    config.model_path = model.path();
    config.input_width = 6;
    config.input_height = 2;
    config.confidence_threshold = 0.5F;
    config.output_layout = detection::YoloOutputLayout::CornersScoreClass;
    ASSERT_TRUE(detector.initialize(config).has_value());

    const auto rows = flatten_corners({
      { 1, 0.5F, 3, 1.5F, 0.9F, 15 },// cat: kept
      { 1, 0.5F, 3, 1.5F, 0.3F, 15 },// under the threshold: dropped
      { 4, 0, 5, 1, 0.7F, 0 },// person: kept
      { 4, 0, 5, 1, 0.6F, 0 },// the same person again: suppressed
      { 0, 0, 1, 1, 0.8F, 80 },// no such class: dropped
      { 2, 0, 1, 1, 0.8F, 2 },// x2 before x1: dropped
    });
    // The frame is twice the input's size each way.
    const auto result = detector.detect(rows, 12, 4);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->boxes.size(), 2U);
    const auto &cat = result->boxes[0];
    EXPECT_EQ(cat.class_id, 15);
    EXPECT_EQ(cat.class_name, "cat");
    EXPECT_FLOAT_EQ(cat.confidence, 0.9F);
    EXPECT_FLOAT_EQ(cat.x, 2.0F);
    EXPECT_FLOAT_EQ(cat.y, 1.0F);
    EXPECT_FLOAT_EQ(cat.width, 4.0F);
    EXPECT_FLOAT_EQ(cat.height, 2.0F);
    EXPECT_EQ(result->boxes[1].class_name, "person");
    EXPECT_FLOAT_EQ(result->boxes[1].confidence, 0.7F);
}

TEST(YoloDetector, ShortRowsNeverReadTheNextRowsValues)
{
    // One class score per row while the detector expects eighty: the next row's cx must not become class 1.
    constexpr YoloReshapeGeometry kOneScore{ 2, 6, 6, 6 };
    const TempFile model("kataglyphis-yolo6", ".onnx", kataglyphis::test::yolo_reshape_model(kOneScore));
    detection::YoloDetector detector;
    detection::YoloConfig config;
    config.model_path = model.path();
    config.input_width = 6;
    config.input_height = 2;
    config.confidence_threshold = 0.4F;
    ASSERT_TRUE(detector.initialize(config).has_value());

    std::vector<float> rows(kOneScore.elements(), 0.0F);
    const std::vector<float> first_two{ 3, 3, 2, 2, 0.9F, 0.5F, 0.99F, 0, 0, 0, 0, 0 };
    std::copy(first_two.begin(), first_two.end(), rows.begin());
    const auto result = detector.detect(rows, 6, 2);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->boxes.size(), 1U);
    EXPECT_EQ(result->boxes[0].class_id, 0);
    EXPECT_NEAR(result->boxes[0].confidence, 0.45F, 1e-5F);
}

TEST(YoloDetector, NonFiniteValuesNeverBecomeBoxes)
{
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());
    constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();
    constexpr float kInf = std::numeric_limits<float>::infinity();
    const auto rows = flatten({
      { 1, 1, 1, 1, kNaN, 0.9F, 0 },
      { 1, 1, 1, 1, kInf, 0.9F, 0 },
      { kNaN, 1, 1, 1, 0.9F, 0.9F, 0 },
      { 1, 1, kInf, 1, 0.9F, 0.9F, 0 },
      { 1, 1, 1, 1, 0.9F, kNaN, kNaN },
      { 1, 1, 1, -kInf, 0.9F, 0.9F, 0 },
    });
    const auto result = detector.detect(rows, 7, 2);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result->boxes.empty());
}

TEST(YoloDetector, AWrongSizedImageIsInvalidInputShape)
{
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());
    const std::vector<float> rows(kTwoClasses.elements() - 1, 0.0F);
    const auto result = detector.detect(rows, 7, 2);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), detection::OnnxError::InvalidInputShape);
}

TEST(YoloDetector, AMovedDetectorStillDetects)
{
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());
    detection::YoloDetector moved(std::move(detector));
    const auto rows = flatten({ { 3, 1, 2, 2, 0.9F, 0.9F, 0 }, {}, {}, {}, {}, {} });
    const auto result = moved.detect(rows, 7, 2);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->boxes.size(), 1U);
}

TEST(YoloDetectorGStreamer, DecodesAFramePushedThroughAppsrc)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("appsrc", "appsink");
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());

    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline
        .create_pipeline_from_string("appsrc name=src format=time "
                                     "caps=video/x-raw,format=RGB,width=14,height=6,framerate=0/1 "
                                     "! appsink name=sink sync=false")
        .has_value());
    ASSERT_TRUE(pipeline.start().has_value());

    // RGB rows align to four bytes; white normalises to one in every NCHW channel.
    std::vector<std::uint8_t> pixels(44 * 6, 255);
    gstreamer::FrameMetadata metadata;
    metadata.timestamp_ns = 0;
    metadata.duration_ns = 1000;
    ASSERT_TRUE(pipeline.push_buffer(pixels.data(), pixels.size(), metadata).has_value());

    const auto result = detector.detect_from_gstreamer(pipeline, 10000);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->original_width, 14U);
    EXPECT_EQ(result->original_height, 6U);
    ASSERT_EQ(result->boxes.size(), 1U);
    EXPECT_EQ(result->boxes[0].class_name, "person");
    EXPECT_FLOAT_EQ(result->boxes[0].width, 2.0F);
    EXPECT_FLOAT_EQ(result->boxes[0].height, 3.0F);
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(YoloDetectorGStreamer, RejectsFramesWithoutVideoGeometry)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("appsrc", "appsink");
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());

    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(
      pipeline.create_pipeline_from_string("appsrc name=src format=time ! appsink name=sink sync=false").has_value());
    ASSERT_TRUE(pipeline.start().has_value());

    gstreamer::FrameMetadata metadata;
    std::vector<float> too_short(kTwoClasses.elements() - 1, 0.0F);
    ASSERT_TRUE(pipeline.push_buffer(too_short.data(), too_short.size() * sizeof(float), metadata).has_value());
    const auto short_frame = detector.detect_from_gstreamer(pipeline, 10000);
    ASSERT_FALSE(short_frame.has_value());
    EXPECT_EQ(short_frame.error(), detection::OnnxError::InvalidInputShape);

    std::vector<std::uint8_t> odd_bytes(7, 1);
    ASSERT_TRUE(pipeline.push_buffer(odd_bytes.data(), odd_bytes.size(), metadata).has_value());
    const auto odd_frame = detector.detect_from_gstreamer(pipeline, 10000);
    ASSERT_FALSE(odd_frame.has_value());
    EXPECT_EQ(odd_frame.error(), detection::OnnxError::InvalidInputShape);
    EXPECT_TRUE(pipeline.stop().has_value());
}

TEST(YoloDetectorGStreamer, APipelineWithoutAppsinkGivesNoInput)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("fakesrc", "fakesink");
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::YoloDetector detector;
    ASSERT_TRUE(detector.initialize(two_class_config(model)).has_value());
    gstreamer::GStreamerPipeline pipeline;
    ASSERT_TRUE(pipeline.create_pipeline_from_string("fakesrc num-buffers=1 ! fakesink").has_value());
    const auto result = detector.detect_from_gstreamer(pipeline, 100);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), detection::OnnxError::InputAllocationFailed);
}

TEST(VideoDetectorPipeline, RunsTheDetectorOnEveryFrame)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));

    detection::VideoDetectionConfig config;
    config.yolo_config = two_class_config(model);
    config.gstreamer_config.pipeline_description =
      "videotestsrc num-buffers=3 pattern=black ! video/x-raw,format=RGB,width=640,height=480,framerate=30/1 "
      "! appsink name=sink sync=false";

    detection::VideoDetectorPipeline pipeline;
    ASSERT_TRUE(pipeline.initialize(config).has_value());
    EXPECT_FALSE(pipeline.is_running());

    kataglyphis::test::EventCounter frames;
    kataglyphis::test::EventCounter detections;
    std::mutex sizes_mutex;
    std::vector<std::uint32_t> widths;
    pipeline.set_frame_callback([&](const gstreamer::BufferInfo &) { frames.add(); });
    pipeline.set_detection_callback([&](const detection::DetectionResult &result, const gstreamer::BufferInfo &) {
        {
            std::scoped_lock lock(sizes_mutex);
            widths.push_back(result.original_width);
        }
        detections.add();
    });

    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(pipeline.is_running());
    EXPECT_TRUE(frames.wait_for(3, kataglyphis::test::kStreamTimeout));
    EXPECT_TRUE(detections.wait_for(3, kataglyphis::test::kStreamTimeout));
    EXPECT_TRUE(pipeline.stop().has_value());
    EXPECT_FALSE(pipeline.is_running());

    EXPECT_EQ(frames.count(), 3);
    EXPECT_EQ(detections.count(), 3);
    std::scoped_lock lock(sizes_mutex);
    EXPECT_EQ(widths, (std::vector<std::uint32_t>{ 640, 640, 640 }));
}

TEST(VideoDetectorPipeline, ReportsUnsupportedFramesThroughTheErrorCallback)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::VideoDetectionConfig config;
    config.yolo_config = two_class_config(model);
    config.gstreamer_config.pipeline_description =
      "videotestsrc num-buffers=2 pattern=black ! video/x-raw,format=GRAY8,width=8,height=4 ! appsink sync=false";
    detection::VideoDetectorPipeline pipeline;
    ASSERT_TRUE(pipeline.initialize(config).has_value());
    kataglyphis::test::EventCounter errors;
    pipeline.set_error_callback([&](detection::OnnxError error) {
        EXPECT_EQ(error, detection::OnnxError::InvalidInputType);
        errors.add();
    });
    ASSERT_TRUE(pipeline.start().has_value());
    EXPECT_TRUE(errors.wait_for(2, kataglyphis::test::kStreamTimeout));
    EXPECT_TRUE(pipeline.stop().has_value());
    EXPECT_EQ(pipeline.last_error(), detection::OnnxError::InvalidInputType);
}

TEST(FramePreprocessing, ReadsPaddedRgbRowsAndNormalisesIntoSeparateChannels)
{
    gstreamer::BufferInfo frame;
    frame.metadata.width = 2;
    frame.metadata.height = 2;
    frame.metadata.format = "RGB";
    frame.metadata.row_stride_bytes = 8;
    frame.metadata.plane_offset_bytes = 3;
    const std::vector<unsigned char> bytes{ 9, 9, 9, 255, 0, 0, 0, 255, 0, 9, 9, 0, 0, 255, 255, 255, 255 };
    for (const auto value : bytes) { frame.data.push_back(static_cast<std::byte>(value)); }
    frame.size = frame.data.size();
    const auto result = detection::preprocess_frame(frame, 2, 2);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->data, (std::vector<float>{ 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1 }));
    frame.metadata.row_stride_bytes = 5;
    EXPECT_EQ(
      kataglyphis::test::error_of(detection::preprocess_frame(frame, 2, 2)), detection::OnnxError::InvalidInputShape);
    frame.metadata.row_stride_bytes = 8;
    frame.size--;
    EXPECT_EQ(
      kataglyphis::test::error_of(detection::preprocess_frame(frame, 2, 2)), detection::OnnxError::InvalidInputShape);
}

TEST(FramePreprocessing, MatchesTheSharedModelAntContract)
{
    const auto contract = nlohmann::json::parse(kInferenceContract, nullptr, false);
    ASSERT_FALSE(contract.is_discarded());
    ASSERT_EQ(contract["schema_version"], 1);
    for (const auto &item : contract["cases"]) {
        SCOPED_TRACE(item["name"].get<std::string>());
        gstreamer::BufferInfo frame;
        frame.metadata.width = item["width"].get<std::uint32_t>();
        frame.metadata.height = item["height"].get<std::uint32_t>();
        frame.metadata.format = item["pixel_format"].get<std::string>();
        frame.metadata.row_stride_bytes = item["row_stride_bytes"].get<std::int64_t>();
        frame.metadata.plane_offset_bytes = item["plane_offset_bytes"].get<std::size_t>();
        for (const auto value : item["data"].get<std::vector<unsigned char>>()) {
            frame.data.push_back(static_cast<std::byte>(value));
        }
        frame.size = frame.data.size();
        const auto mode = item["mode"] == "letterbox" ? detection::FramePreprocessMode::Letterbox
                                                      : detection::FramePreprocessMode::Stretch;
        const auto result = detection::preprocess_frame(
          frame, item["input_width"].get<std::uint32_t>(), item["input_height"].get<std::uint32_t>(), mode);
        ASSERT_TRUE(result.has_value());
        const auto expected = item["expected_nchw"].get<std::vector<float>>();
        ASSERT_EQ(result->data.size(), expected.size());
        for (std::size_t i = 0; i < expected.size(); ++i) { EXPECT_NEAR(result->data[i], expected[i], 1e-6F) << i; }
        EXPECT_NEAR(result->mapping.scale_x, item["mapping"]["scale_x"].get<float>(), 1e-6F);
        EXPECT_NEAR(result->mapping.scale_y, item["mapping"]["scale_y"].get<float>(), 1e-6F);
        EXPECT_FLOAT_EQ(result->mapping.pad_x, item["mapping"]["pad_x"].get<float>());
        EXPECT_FLOAT_EQ(result->mapping.pad_y, item["mapping"]["pad_y"].get<float>());
    }
}

TEST(FramePreprocessing, LetterboxesRgbaAndReturnsTheActualPixelMapping)
{
    gstreamer::BufferInfo frame;
    frame.metadata.width = 2;
    frame.metadata.height = 1;
    frame.metadata.format = "RGBA";
    const std::vector<unsigned char> bytes{ 255, 0, 0, 0, 0, 255, 0, 17 };
    for (const auto value : bytes) { frame.data.push_back(static_cast<std::byte>(value)); }
    frame.size = frame.data.size();
    const auto result = detection::preprocess_frame(frame, 4, 4, detection::FramePreprocessMode::Letterbox);
    ASSERT_TRUE(result.has_value());
    EXPECT_FLOAT_EQ(result->mapping.scale_x, 2.0F);
    EXPECT_FLOAT_EQ(result->mapping.scale_y, 2.0F);
    EXPECT_FLOAT_EQ(result->mapping.pad_y, 1.0F);
    EXPECT_FLOAT_EQ(result->data[0], 114.0F / 255.0F);
    EXPECT_FLOAT_EQ(result->data[4], 1.0F);
    EXPECT_FLOAT_EQ(result->data[5], 1.0F);
    EXPECT_FLOAT_EQ(result->data[6], 0.0F);
    EXPECT_FLOAT_EQ(result->data[16 + 6], 1.0F);
    EXPECT_FLOAT_EQ(result->data[32 + 4], 0.0F);
    frame.metadata.format = "GRAY8";
    EXPECT_EQ(
      kataglyphis::test::error_of(detection::preprocess_frame(frame, 4, 4)), detection::OnnxError::InvalidInputType);
}

TEST(VideoDetectorPipeline, AMovedPipelineStillRunsTheDetector)
{
    KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS("videotestsrc", "capsfilter", "appsink");
    const TempFile model("kataglyphis-yolo", ".onnx", kataglyphis::test::yolo_reshape_model(kTwoClasses));
    detection::VideoDetectionConfig config;
    config.yolo_config = two_class_config(model);
    config.gstreamer_config.pipeline_description =
      "videotestsrc num-buffers=2 pattern=black ! video/x-raw,format=RGBA,width=6,height=7,framerate=30/1 "
      "! appsink name=sink sync=false";

    // The factories hand their pipeline out by move, so the frame path must not hold on to the original object.
    detection::VideoDetectorPipeline original;
    ASSERT_TRUE(original.initialize(config).has_value());
    detection::VideoDetectorPipeline moved(std::move(original));

    kataglyphis::test::EventCounter detections;
    moved.set_detection_callback(
      [&](const detection::DetectionResult &, const gstreamer::BufferInfo &) { detections.add(); });
    ASSERT_TRUE(moved.start().has_value());
    EXPECT_TRUE(detections.wait_for(2, kataglyphis::test::kStreamTimeout));
    EXPECT_TRUE(moved.stop().has_value());
}

TEST(VideoDetectorPipeline, FactoriesFailOnAMissingModel)
{
    ASSERT_TRUE(gstreamer::GStreamerPipeline::initialize_gstreamer().has_value());
    const auto missing = kataglyphis::test::missing_path("yolo.onnx");

    const auto video = detection::create_video_detection_pipeline("clip.mp4", missing, 64, 48);
    ASSERT_FALSE(video.has_value());
    EXPECT_EQ(video.error(), detection::OnnxError::ModelLoadFailed);

    const auto camera = detection::create_camera_detection_pipeline("/dev/video0", missing, 64, 48, 30);
    ASSERT_FALSE(camera.has_value());
    EXPECT_EQ(camera.error(), detection::OnnxError::ModelLoadFailed);
}
