#pragma once

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <locale>
#include <optional>
#include <sstream>
#include <utility>
#include <vector>

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

// The frame jpegdec gives this image, or an empty optional after printing why.
static auto decode_detector_image(const std::filesystem::path &image_path) -> std::optional<gstreamer::BufferInfo>
{
    std::error_code error;
    const bool image_exists = std::filesystem::is_regular_file(image_path, error);
    const auto absolute_image = std::filesystem::absolute(image_path, error);
    if (!image_exists || error || !gstreamer::GStreamerPipeline::initialize_gstreamer()) {
        std::cerr << "Could not open the detector image or initialize GStreamer\n";
        return std::nullopt;
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
        return std::nullopt;
    }
    const auto frame = pipeline.pull_sample(10000);
    const auto stopped = pipeline.stop();
    if (!frame || !stopped) {
        std::cerr << "Could not read the detector image frame\n";
        return std::nullopt;
    }
    return *frame;
}

// One JSON line for quality-report.sh --perf-host: warm p50 and p95, or why this provider cannot run here.
static auto run_detector_latency(const detection::YoloConfig &config,
  const std::filesystem::path &image_path,
  const int runs) -> int
{
    constexpr int warm_runs = 5;
    const auto frame = decode_detector_image(image_path);
    if (!frame) { return 1; }
    detection::YoloDetector detector;
    if (const auto started = detector.initialize(config); !started) {
        if (started.error() == inference::OnnxError::ProviderUnavailable) {
            std::cout << "{\"not_collected\":\"ProviderUnavailable\"}\n";
            return 0;
        }
        std::cerr << "Could not initialize the image detector\n";
        return 1;
    }
    std::vector<double> samples;
    samples.reserve(static_cast<std::size_t>(runs));
    for (int i = 0; i < warm_runs + runs; ++i) {
        const auto start = std::chrono::steady_clock::now();
        if (!detector.detect_frame(*frame)) {
            std::cerr << "Image detection failed\n";
            return 1;
        }
        const std::chrono::duration<double, std::milli> taken = std::chrono::steady_clock::now() - start;
        if (i >= warm_runs) { samples.push_back(taken.count()); }
    }
    std::ranges::sort(samples);
    const auto rank = [&samples](const double fraction) {
        return samples[std::min(
          samples.size() - 1, static_cast<std::size_t>(fraction * static_cast<double>(samples.size())))];
    };
    std::cout << "{\"p50_ms\":" << rank(0.5) << ",\"p95_ms\":" << rank(0.95) << "}\n";
    return 0;
}

static auto run_detector_image(const detection::YoloConfig &config,
  const std::filesystem::path &image_path,
  const std::filesystem::path &output_path,
  const std::filesystem::path &repeat_output_path,
  const std::filesystem::path &profile_prefix) -> int
{
    // Before any output exists: a missing image left an empty file and directory that refused the corrected run.
    const auto frame = decode_detector_image(image_path);
    if (!frame) { return 1; }
    std::error_code error;
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
