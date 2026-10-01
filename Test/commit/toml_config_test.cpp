#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <string>
#include <string_view>
#include <vector>

#include "kShippedInferenceConfig.inc"

import kataglyphis.toml_config;

namespace cfg = kataglyphis::config;
using kataglyphis::test::TempFile;

namespace {

constexpr std::string_view kFullConfig = R"(
[model]
model_path = "models/custom.onnx"
framework = "tflite"
input_width = 320
input_height = 256
confidence_threshold = 0.6
iou_threshold = 0.3
labels = ["cat", "dog"]

[pipeline]
camera_device = "/dev/video2"
capture_width = 1920
capture_height = 1080
capture_fps = 60
enable_inference = false
enable_overlay = false

[general]
log_level = "debug"
)";

}// namespace

TEST(TomlConfig, DefaultsDescribeTheCocoDetector)
{
    const auto config = cfg::get_default_inference_config();
    EXPECT_TRUE(config.model.model_path.empty());
    EXPECT_EQ(config.model.framework, "onnx");
    EXPECT_EQ(config.model.input_width, 640U);
    EXPECT_EQ(config.model.input_height, 640U);
    EXPECT_DOUBLE_EQ(config.model.confidence_threshold, 0.25);
    EXPECT_DOUBLE_EQ(config.model.iou_threshold, 0.45);
    ASSERT_EQ(config.model.labels.size(), 10U);
    EXPECT_EQ(config.model.labels.front(), "person");
    EXPECT_EQ(config.model.labels.back(), "traffic light");
    EXPECT_EQ(config.pipeline.camera_device, "0");
    EXPECT_EQ(config.pipeline.capture_width, 1280U);
    EXPECT_EQ(config.pipeline.capture_height, 720U);
    EXPECT_EQ(config.pipeline.capture_fps, 30U);
    EXPECT_TRUE(config.pipeline.enable_inference);
    EXPECT_TRUE(config.pipeline.enable_overlay);
    EXPECT_EQ(config.log_level, "info");
}

TEST(TomlConfig, EmptyDocumentKeepsTheStructDefaultsWithoutLabels)
{
    const auto config = cfg::parse_inference_config("");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->model.input_width, 640U);
    EXPECT_EQ(config->pipeline.capture_fps, 30U);
    EXPECT_EQ(config->log_level, "info");
    // Unlike get_default_inference_config(), parsing starts from no labels at all.
    EXPECT_TRUE(config->model.labels.empty());
}

TEST(TomlConfig, ParsesEveryField)
{
    const auto config = cfg::parse_inference_config(std::string(kFullConfig));
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->model.model_path, "models/custom.onnx");
    EXPECT_EQ(config->model.framework, "tflite");
    EXPECT_EQ(config->model.input_width, 320U);
    EXPECT_EQ(config->model.input_height, 256U);
    EXPECT_DOUBLE_EQ(config->model.confidence_threshold, 0.6);
    EXPECT_DOUBLE_EQ(config->model.iou_threshold, 0.3);
    EXPECT_EQ(config->model.labels, (std::vector<std::string>{ "cat", "dog" }));
    EXPECT_EQ(config->pipeline.camera_device, "/dev/video2");
    EXPECT_EQ(config->pipeline.capture_width, 1920U);
    EXPECT_EQ(config->pipeline.capture_height, 1080U);
    EXPECT_EQ(config->pipeline.capture_fps, 60U);
    EXPECT_FALSE(config->pipeline.enable_inference);
    EXPECT_FALSE(config->pipeline.enable_overlay);
    EXPECT_EQ(config->log_level, "debug");
}

TEST(TomlConfig, PartialDocumentOnlyOverridesWhatItNames)
{
    const auto config = cfg::parse_inference_config("[pipeline]\ncapture_fps = 15\n");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->pipeline.capture_fps, 15U);
    EXPECT_EQ(config->pipeline.capture_width, 1280U);
    EXPECT_EQ(config->model.input_width, 640U);
    EXPECT_EQ(config->model.framework, "onnx");
}

TEST(TomlConfig, MalformedDocumentsAreParseErrors)
{
    for (const std::string_view document : { "[model",
           "input_width = ",
           "[model]\ninput_width = 1\ninput_width = 2\n",
           "= 3",
           "[model]\nlabels = [\"a\"" }) {
        const auto config = cfg::parse_inference_config(std::string(document));
        ASSERT_FALSE(config.has_value()) << document;
        EXPECT_EQ(config.error(), cfg::TomlConfigError::ParseError) << document;
    }
}

TEST(TomlConfig, WrongTypesFallBackToTheDefaults)
{
    const auto config = cfg::parse_inference_config(R"(
[model]
model_path = 5
framework = true
input_width = "wide"
labels = "person"

[pipeline]
camera_device = 0
enable_inference = "yes"

[general]
log_level = 3
)");
    ASSERT_TRUE(config.has_value());
    EXPECT_TRUE(config->model.model_path.empty());
    EXPECT_EQ(config->model.framework, "onnx");
    EXPECT_EQ(config->model.input_width, 640U);
    EXPECT_TRUE(config->model.labels.empty());
    EXPECT_EQ(config->pipeline.camera_device, "0");
    EXPECT_TRUE(config->pipeline.enable_inference);
    EXPECT_EQ(config->log_level, "info");
}

TEST(TomlConfig, LabelArraysKeepOnlyTheirStrings)
{
    const auto config = cfg::parse_inference_config("[model]\nlabels = [1, \"cat\", true, \"dog\", 2.5]\n");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->model.labels, (std::vector<std::string>{ "cat", "dog" }));
}

TEST(TomlConfig, OutOfRangeIntegersFallBackToTheDefaults)
{
    const auto config = cfg::parse_inference_config(
      "[model]\ninput_width = -1\ninput_height = 4294967296\n[pipeline]\ncapture_fps = -30\n");
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->model.input_width, 640U);
    EXPECT_EQ(config->model.input_height, 640U);
    EXPECT_EQ(config->pipeline.capture_fps, 30U);
}

TEST(TomlConfig, IntegerThresholdsReadAsDoubles)
{
    const auto config = cfg::parse_inference_config("[model]\nconfidence_threshold = 1\niou_threshold = 0\n");
    ASSERT_TRUE(config.has_value());
    EXPECT_DOUBLE_EQ(config->model.confidence_threshold, 1.0);
    EXPECT_DOUBLE_EQ(config->model.iou_threshold, 0.0);
}

TEST(TomlConfig, TheShippedConfigParses)
{
    const auto config = cfg::parse_inference_config(std::string(kShippedInferenceConfig));
    ASSERT_TRUE(config.has_value());
    EXPECT_EQ(config->model.model_path, "models/yolo26n.onnx");
    EXPECT_EQ(config->model.framework, "onnx");
    EXPECT_EQ(config->model.input_width, 640U);
    EXPECT_EQ(config->model.input_height, 640U);
    ASSERT_EQ(config->model.labels.size(), 80U);
    EXPECT_EQ(config->model.labels.front(), "person");
    EXPECT_EQ(config->model.labels.back(), "toothbrush");
    EXPECT_EQ(config->pipeline.capture_width, 1280U);
    EXPECT_EQ(config->pipeline.capture_height, 720U);
    EXPECT_EQ(config->pipeline.capture_fps, 30U);
    EXPECT_EQ(config->log_level, "info");
}

TEST(TomlConfig, LoadsTheSameConfigFromAFile)
{
    const TempFile file("kataglyphis-inference", ".toml", kFullConfig);
    const auto loaded = cfg::load_inference_config(file.path());
    const auto parsed = cfg::parse_inference_config(std::string(kFullConfig));
    ASSERT_TRUE(loaded.has_value());
    ASSERT_TRUE(parsed.has_value());
    EXPECT_EQ(loaded->model.model_path, parsed->model.model_path);
    EXPECT_EQ(loaded->model.labels, parsed->model.labels);
    EXPECT_EQ(loaded->pipeline.capture_fps, parsed->pipeline.capture_fps);
    EXPECT_EQ(loaded->log_level, parsed->log_level);
}

TEST(TomlConfig, MissingFileIsFileNotFound)
{
    const auto config = cfg::load_inference_config(kataglyphis::test::missing_path("inference.toml"));
    ASSERT_FALSE(config.has_value());
    EXPECT_EQ(config.error(), cfg::TomlConfigError::FileNotFound);
}

TEST(TomlConfig, MalformedFileIsAParseError)
{
    const TempFile file("kataglyphis-inference-broken", ".toml", "[model\n");
    const auto config = cfg::load_inference_config(file.path());
    ASSERT_FALSE(config.has_value());
    EXPECT_EQ(config.error(), cfg::TomlConfigError::ParseError);
}
