#pragma once

#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <locale>
#include <optional>
#include <sstream>
#include <utility>

static auto write_detector_result(std::ofstream &output, const detection::DetectionResult &result) -> bool
{
    output << std::setprecision(std::numeric_limits<float>::max_digits10)
           << "{\"schema_version\":1,\"width\":" << result.original_width << ",\"height\":" << result.original_height
           << ",\"detections\":[";
    bool first = true;
    for (const auto &box : result.boxes) {
        if (!first) { output << ','; }
        first = false;
        output << "{\"class\":" << box.class_id << ",\"score\":" << box.confidence << ",\"box\":[" << box.x << ','
               << box.y << ',' << box.x + box.width << ',' << box.y + box.height << "]}";
    }
    output << "]}\n";
    output.close();
    return static_cast<bool>(output);
}

static auto run_detector_image(const std::filesystem::path &model_path,
  const std::filesystem::path &image_path,
  const std::filesystem::path &output_path,
  const std::filesystem::path &repeat_output_path,
  inference::ExecutionProvider provider,
  int device_id,
  const std::filesystem::path &profile_prefix) -> int
{
    std::error_code error;
    const bool image_exists = std::filesystem::is_regular_file(image_path, error);
    const auto absolute_image = std::filesystem::absolute(image_path, error);
    if (!image_exists || error || !gstreamer::GStreamerPipeline::initialize_gstreamer()) {
        std::cerr << "Could not open the detector image or initialize GStreamer\n";
        return 1;
    }
    std::ofstream output(output_path, std::ios::out | std::ios::noreplace);
    if (!output) {
        std::cerr << "Detector output must be a new file\n";
        return 1;
    }
    output.imbue(std::locale::classic());
    std::ofstream repeat_output;
    if (!repeat_output_path.empty()) {
        repeat_output.open(repeat_output_path, std::ios::out | std::ios::noreplace);
        if (!repeat_output) {
            std::cerr << "Repeated detector output must be a new file\n";
            return 1;
        }
        repeat_output.imbue(std::locale::classic());
    }
    if (!std::filesystem::create_directory(profile_prefix, error)) {
        std::cerr << "Detector profile must be a new directory\n";
        return 1;
    }
    std::ostringstream location;
    location << std::quoted(absolute_image.string());
    gstreamer::PipelineConfig pipeline_config;
    pipeline_config.pipeline_description =
      "filesrc location=" + location.str()
      + " ! jpegdec ! videoconvert ! video/x-raw,format=RGB ! appsink name=sink sync=false";
    gstreamer::GStreamerPipeline pipeline;
    if (!pipeline.create_pipeline(pipeline_config) || !pipeline.start()) {
        std::cerr << "Could not decode the detector image\n";
        return 1;
    }
    const auto frame = pipeline.pull_sample(10000);
    const auto stopped = pipeline.stop();
    if (!frame || !stopped) {
        std::cerr << "Could not read the detector image frame\n";
        return 1;
    }
    detection::YoloConfig config;
    config.model_path = model_path;
    config.execution_provider = provider;
    config.device_id = device_id;
    config.output_layout = detection::YoloOutputLayout::CornersScoreClass;
    detection::YoloDetector detector;
    if (!detector.initialize(config, profile_prefix / "ort")) {
        std::cerr << "Could not initialize the image detector\n";
        return 1;
    }
    const auto result = detector.detect_frame(*frame);
    if (!result) {
        std::cerr << "Image detection failed\n";
        return 1;
    }
    std::optional<detection::DetectionResult> repeated;
    if (!repeat_output_path.empty()) {
        auto second = detector.detect_frame(*frame);
        if (!second) {
            std::cerr << "Repeated image detection failed\n";
            return 1;
        }
        repeated = std::move(*second);
    }
    const auto profile = detector.end_profiling();
    if (!profile) {
        std::cerr << "Image detection or profiling failed\n";
        return 1;
    }
    if (!write_detector_result(output, *result)
        || (!repeat_output_path.empty() && !write_detector_result(repeat_output, *repeated))) {
        std::cerr << "Could not write detector results\n";
        return 1;
    }
    std::cout << "Detector image profile: " << *profile << "\n";
    return 0;
}
