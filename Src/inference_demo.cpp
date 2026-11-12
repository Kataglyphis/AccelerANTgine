#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

#include "kShippedInferenceConfig.inc"

#include "demo_device.hpp"
#include "demo_model.hpp"
#include "standalone_gstreamer_environment.hpp"

import kataglyphis.onnx_inference;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.toml_config;
import kataglyphis.yolo_detector;
import kataglyphis.project_config;
import kataglyphis.log;

namespace inference = kataglyphis::inference;
namespace gstreamer = kataglyphis::gstreamer;
namespace detection = kataglyphis::detection;

#include "demo_detector_image.hpp"

static void print_detection_results(const detection::DetectionResult &result)
{
    std::cout << "Detection Results:\n";
    std::cout << "  Inference time: " << result.inference_time_ms << " ms\n";
    std::cout << "  Original size: " << result.original_width << "x" << result.original_height << "\n";
    std::cout << "  Objects detected: " << result.boxes.size() << "\n\n";

    for (const auto &box : result.boxes) {
        std::cout << "  - " << box.class_name << " (confidence: " << (box.confidence * 100.0F) << "%)\n"
                  << "    Position: (" << box.x << ", " << box.y << ")\n"
                  << "    Size: " << box.width << "x" << box.height << "\n\n";
    }
}

static auto run_onnx_inference_example(const detection::YoloConfig &base, const std::filesystem::path &profile_prefix)
  -> int
{
    std::cout << "=== ONNX Runtime Inference Example ===\n\n";

    inference::OnnxInferenceEngine engine;

    const auto &model_path = base.model_path;
    auto config = inference::create_default_session_config(model_path);
    config.intra_op_num_threads = base.intra_op_num_threads;
    config.inter_op_num_threads = base.inter_op_num_threads;
    config.execution_provider = base.execution_provider;
    config.device_id = base.device_id;
    config.profiling_prefix = profile_prefix;

    std::cout << "Initializing ONNX Runtime with model: " << model_path << "\n";

    auto init_result = engine.initialize(config);
    if (!init_result) {
        std::cerr << "Failed to initialize ONNX Runtime: " << static_cast<int>(init_result.error()) << "\n";
        return 1;
    }

    std::cout << "ONNX Runtime initialized successfully!\n\n";

    auto input_names = engine.get_input_names();
    auto output_names = engine.get_output_names();

    if (input_names.size() != 1) {
        std::cerr << "The ONNX example requires a model with exactly one input\n";
        return 1;
    }

    std::cout << "Model inputs:\n";
    for (const auto &name : input_names) {
        auto shape = engine.get_input_shape(name);
        if (shape) {
            std::cout << "  " << name << ": [";
            for (std::size_t i = 0; i < shape->dimensions.size(); ++i) {
                if (i > 0) { std::cout << ", "; }
                std::cout << shape->dimensions[i];
            }
            std::cout << "]\n";
        }
    }

    std::cout << "\nModel outputs:\n";
    for (const auto &name : output_names) {
        auto shape = engine.get_output_shape(name);
        if (shape) {
            std::cout << "  " << name << ": [";
            for (std::size_t i = 0; i < shape->dimensions.size(); ++i) {
                if (i > 0) { std::cout << ", "; }
                std::cout << shape->dimensions[i];
            }
            std::cout << "]\n";
        }
    }

    std::cout << "\nPerforming inference on dummy data...\n";

    inference::TensorShape input_shape;
    input_shape.dimensions = { 1, 3, 640, 640 };
    std::size_t total_elements = input_shape.total_elements();

    std::vector<float> dummy_input(total_elements, 0.5F);

    auto result = engine.run_inference(dummy_input, input_shape, input_names[0]);
    if (!result) {
        std::cerr << "Inference failed: " << static_cast<int>(result.error()) << "\n";
        return 1;
    }

    std::cout << "Inference completed!\n";
    std::cout << "  Inference time: " << result->inference_time_ms << " ms\n";
    std::cout << "  Number of outputs: " << result->outputs.size() << "\n";

    for (std::size_t i = 0; i < result->outputs.size(); ++i) {
        const auto &output = result->outputs[i];
        std::cout << "  Output " << i << " shape: [";
        for (std::size_t j = 0; j < output.shape.dimensions.size(); ++j) {
            if (j > 0) { std::cout << ", "; }
            std::cout << output.shape.dimensions[j];
        }
        std::cout << "] (" << output.data.size() << " elements)\n";
    }

    if (!profile_prefix.empty()) {
        const auto profile = engine.end_profiling();
        if (!profile) {
            std::cerr << "Could not finish ONNX Runtime profiling\n";
            return 1;
        }
        std::cout << "Profile: " << *profile << "\n";
    }

    return 0;
}

static auto pull_gstreamer_samples() -> int
{
    gstreamer::GStreamerPipeline pipeline;

    gstreamer::PipelineConfig config;
    config.pipeline_description =
      "videotestsrc num-buffers=100 ! "
      "video/x-raw,width=640,height=480,framerate=30/1 ! "
      "videoconvert ! "
      "appsink name=test_sink sync=false";

    std::cout << "Creating pipeline...\n";
    auto create_result = pipeline.create_pipeline(config);
    if (!create_result) {
        std::cerr << "Failed to create pipeline: " << static_cast<int>(create_result.error()) << "\n";
        return 1;
    }

    std::cout << "Starting pipeline...\n";
    auto start_result = pipeline.start();
    if (!start_result) {
        std::cerr << "Failed to start pipeline: " << static_cast<int>(start_result.error()) << "\n";
        return 1;
    }

    std::cout << "Pipeline running! Processing 10 buffers...\n";

    int result = 0;
    for (int i = 0; i < 10 && result == 0; ++i) {
        auto sample = pipeline.pull_sample(1000);
        if (sample) {
            std::cout << "Sample " << i + 1 << ": " << sample->size << " bytes, " << sample->metadata.width << "x"
                      << sample->metadata.height << "\n";
        } else {
            std::cerr << "No sample " << i + 1 << " within a second\n";
            result = 1;
        }
    }

    std::cout << "Stopping pipeline...\n";
    if (!pipeline.stop()) {
        std::cerr << "Failed to stop pipeline\n";
        result = 1;
    }
    return result;
}

static auto run_gstreamer_pipeline_example() -> int
{
    std::cout << "\n=== GStreamer Pipeline Example ===\n\n";

    auto init_result = gstreamer::GStreamerPipeline::initialize_gstreamer();
    if (!init_result) {
        std::cerr << "Failed to initialize GStreamer: " << static_cast<int>(init_result.error()) << "\n";
        return 1;
    }

    std::cout << "GStreamer initialized successfully!\n";

    // The pipeline must release its elements before gst_deinit.
    const int result = pull_gstreamer_samples();

    gstreamer::GStreamerPipeline::deinitialize_gstreamer();
    if (result == 0) { std::cout << "GStreamer example completed!\n"; }

    return result;
}

static auto run_yolo_detection_example(const detection::YoloConfig &config) -> int
{
    std::cout << "\n=== YOLO Detection Example ===\n\n";

    detection::YoloDetector detector;

    std::cout << "Initializing YOLO detector with model: " << config.model_path << "\n";

    auto init_result = detector.initialize(config);
    if (!init_result) {
        std::cerr << "Failed to initialize YOLO detector: " << static_cast<int>(init_result.error()) << "\n";
        return 1;
    }

    std::cout << "YOLO detector initialized successfully!\n";
    std::cout << "ORT intra-op threads: " << detector.applied_intra_op_num_threads() << "\n\n";

    std::cout << "Performing detection on dummy image data...\n";

    std::size_t input_size = 3 * 640 * 640;
    std::vector<float> dummy_image(input_size, 0.5F);

    auto result = detector.detect(dummy_image, 640, 480);
    if (!result) {
        std::cerr << "Detection failed: " << static_cast<int>(result.error()) << "\n";
        return 1;
    }

    print_detection_results(*result);

    return 0;
}

static auto run_video_detection_example(const detection::YoloConfig &config) -> int
{
    std::cout << "\n=== Video Detection Pipeline Example ===\n\n";

    auto pipeline_result = detection::create_video_detection_pipeline("test.mp4", config, 640, 480);

    if (!pipeline_result) {
        std::cerr << "Video detection pipeline creation failed: " << static_cast<int>(pipeline_result.error()) << "\n";
        return 1;
    }

    pipeline_result->set_detection_callback(
      [](const detection::DetectionResult &result, const gstreamer::BufferInfo &buffer) -> void {
          std::cout << "Frame " << buffer.metadata.timestamp_ns << ": " << result.boxes.size() << " objects detected\n";
      });

    std::cout << "Starting video detection...\n";
    auto start_result = pipeline_result->start();
    if (!start_result) {
        std::cerr << "Failed to start video detection pipeline\n";
        return 1;
    }

    std::cout << "Processing video...\n";

    std::this_thread::sleep_for(std::chrono::seconds(5));

    (void)pipeline_result->stop();
    std::cout << "Video detection completed!\n";

    return 0;
}

// A synthetic frame exercises the live video inference path without a camera.
static auto run_video_detection_check(const detection::YoloConfig &yolo_config,
  const std::filesystem::path &profile_prefix) -> int
{
    std::mutex mutex;
    std::condition_variable ready;
    bool detected = false;
    bool failed = false;

    detection::VideoDetectionConfig config;
    config.yolo_config = yolo_config;
    config.gstreamer_config.pipeline_description =
      "videotestsrc num-buffers=1 pattern=black ! video/x-raw,format=RGB,width=640,height=480,framerate=30/1 "
      "! appsink name=sink sync=false";

    detection::VideoDetectorPipeline pipeline;
    if (!pipeline.initialize(config, profile_prefix)) {
        std::cerr << "Video detector initialization failed\n";
        return 1;
    }
    pipeline.set_detection_callback([&](const detection::DetectionResult &result, const gstreamer::BufferInfo &) {
        {
            std::scoped_lock lock(mutex);
            detected = result.original_width == 640 && result.original_height == 480;
            failed = !detected;
        }
        ready.notify_one();
    });
    pipeline.set_error_callback([&](detection::OnnxError error) {
        std::cerr << "Video inference failed: " << static_cast<int>(error) << "\n";
        {
            std::scoped_lock lock(mutex);
            failed = true;
        }
        ready.notify_one();
    });
    if (!pipeline.start()) {
        std::cerr << "Video pipeline failed to start: " << pipeline.stream_error().value_or("no reason given") << "\n";
        return 1;
    }
    {
        std::unique_lock lock(mutex);
        (void)ready.wait_for(lock, std::chrono::seconds(60), [&] { return detected || failed; });
    }
    if (const auto broken = pipeline.stream_error()) { std::cerr << "Video stream failed: " << *broken << "\n"; }
    const bool stopped = pipeline.stop().has_value();
    bool success;
    {
        std::scoped_lock lock(mutex);
        success = detected && !failed;
    }
    if (!stopped || !success) {
        std::cerr << "Video pipeline did not produce a valid inference result\n";
        return 1;
    }
    if (!profile_prefix.empty()) {
        const auto profile = pipeline.end_profiling();
        if (!profile) {
            std::cerr << "Could not finish video inference profiling\n";
            return 1;
        }
        std::cout << "Video profile: " << *profile << "\n";
    }
    std::cout << "GStreamer video frame inference passed\n";
    return 0;
}

static void print_usage(const char *program_name)
{
    std::cout << "Usage: " << program_name << " [options]\n\n"
              << "Options:\n"
              << "  --model <path>     ONNX model (default: the config's model_path, bundled if packaged)\n"
              << "  --onnx-only        Run only ONNX inference example\n"
              << "  --config <toml>    Model path, output layout and detector settings (default: the shipped "
                 "inference_config.toml)\n"
              << "  --device <name>    cpu, cuda, migraphx, directml, xnnpack or dnnl (default: "
              << kataglyphis::demo::default_device << ")\n"
              << "  --device-id <id>   Provider device index (default: 0)\n"
              << "  --threads <n>      ONNX Runtime intra-op threads (default: the config's, else 4)\n"
              << "  --profile <prefix> Write an operator profile (--onnx-only or --video-check)\n"
              << "  --detector-latency-runs <n> With --detector-image: warm p50 and p95 as one JSON line\n"
              << "  --gstreamer-only   Run only GStreamer pipeline example\n"
              << "  --yolo-only        Run only YOLO detection example\n"
              << "  --video-only       Run only video detection example\n"
              << "  --video-check      Run model inference on one synthetic GStreamer video frame\n"
              << "  --detector-image <jpg> --detector-output <json> --profile <prefix>\n"
              << "                     Profile a JPEG detector run (new output file and profile directory)\n"
              << "  --detector-repeat-output <json>  Repeat detection in the same session\n"
              << "  --all              Run all examples\n"
              << "  --help             Show this help message\n\n"
              << "Examples:\n"
              << "  " << program_name << " --config resources/configs/inference_config.toml --all\n"
              << "  " << program_name << " --onnx-only\n";
}

auto main(int argc, char *argv[]) -> int
{
#if defined(_WIN32)
    if (!kataglyphis::standalone_gstreamer::isolate_packaged_plugins()) {
        kataglyphis::log::error("Could not isolate the packaged GStreamer environment");
        return 1;
    }
#endif
    std::filesystem::path model_path;
    bool run_onnx = false;
    bool run_gstreamer = false;
    bool run_yolo = false;
    bool run_video = false;
    bool run_video_check = false;
    auto provider = kataglyphis::demo::parse_device<inference::ExecutionProvider>(kataglyphis::demo::default_device);
    if (!provider) {
        kataglyphis::log::error("Invalid packaged default device");
        return 2;
    }
    int device_id = 0;
    int threads = 0;
    bool model_given = false;
    std::filesystem::path config_path;
    std::filesystem::path profile_prefix;
    std::filesystem::path detector_image;
    std::filesystem::path detector_output;
    std::filesystem::path detector_repeat_output;
    int detector_latency_runs = 0;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "--model" && i + 1 < argc) {
            model_path = argv[++i];
            model_given = true;
        } else if (arg == "--config" && i + 1 < argc) {
            config_path = argv[++i];
        } else if (arg == "--threads" && i + 1 < argc) {
            const std::string value = argv[++i];
            const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), threads);
            if (error != std::errc{} || end != value.data() + value.size() || threads < 1) {
                std::cerr << "Invalid thread count: " << value << "\n";
                return 2;
            }
        } else if (arg == "--device" && i + 1 < argc) {
            const std::string device = argv[++i];
            provider = kataglyphis::demo::parse_device<inference::ExecutionProvider>(device);
            if (!provider) {
                std::cerr << "Unknown device: " << device << "\n";
                return 2;
            }
        } else if (arg == "--device-id" && i + 1 < argc) {
            const std::string value = argv[++i];
            const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), device_id);
            if (error != std::errc{} || end != value.data() + value.size() || device_id < 0) {
                std::cerr << "Invalid device index: " << value << "\n";
                return 2;
            }
        } else if (arg == "--profile" && i + 1 < argc) {
            profile_prefix = argv[++i];
        } else if (arg == "--detector-image" && i + 1 < argc) {
            detector_image = argv[++i];
        } else if (arg == "--detector-output" && i + 1 < argc) {
            detector_output = argv[++i];
        } else if (arg == "--detector-repeat-output" && i + 1 < argc) {
            detector_repeat_output = argv[++i];
        } else if (arg == "--detector-latency-runs" && i + 1 < argc) {
            const std::string value = argv[++i];
            const auto *const last = value.data() + value.size();
            const auto parsed = std::from_chars(value.data(), last, detector_latency_runs);
            if (parsed.ec != std::errc{} || parsed.ptr != last || detector_latency_runs <= 0) {
                std::cerr << "Invalid --detector-latency-runs value: " << value << "\n";
                return 2;
            }
        } else if (arg == "--onnx-only") {
            run_onnx = true;
        } else if (arg == "--gstreamer-only") {
            run_gstreamer = true;
        } else if (arg == "--yolo-only") {
            run_yolo = true;
        } else if (arg == "--video-only") {
            run_video = true;
        } else if (arg == "--video-check") {
            run_video_check = true;
        } else if (arg == "--all") {
            run_onnx = true;
            run_gstreamer = true;
            run_yolo = true;
            run_video = true;
        } else if (arg == "--help") {
            print_usage(argv[0]);
            return 0;
        } else {
            std::cerr << "Unknown or incomplete option: " << arg << "\n";
            return 2;
        }
    }

    const auto loaded = config_path.empty()
                          ? kataglyphis::config::parse_inference_config(std::string(kShippedInferenceConfig))
                          : kataglyphis::config::load_inference_config(config_path);
    if (!loaded) {
        std::cerr << "Could not read the config " << config_path << "\n";
        return 2;
    }
    auto configured = detection::yolo_config_from(loaded->model);
    if (!configured) {
        std::cerr << "Invalid output_layout: " << loaded->model.output_layout << "\n";
        return 2;
    }
    detection::YoloConfig base = *configured;
    if (model_given) {
        base.model_path = model_path;
    } else if (config_path.empty()) {
        base.model_path = kataglyphis::demo::default_model(base.model_path);
    }
    if (threads > 0) { base.intra_op_num_threads = threads; }
    base.execution_provider = *provider;
    base.device_id = device_id;
    model_path = base.model_path;

    if (detector_latency_runs > 0) {
        if (detector_image.empty() || !detector_output.empty() || !detector_repeat_output.empty()
            || !profile_prefix.empty() || run_onnx || run_gstreamer || run_yolo || run_video || run_video_check) {
            std::cerr << "Latency runs require an image, without outputs, a profile or other modes\n";
            return 2;
        }
        return run_detector_latency(base, detector_image, detector_latency_runs);
    }
    if (!detector_image.empty() || !detector_output.empty() || !detector_repeat_output.empty()) {
        if (detector_image.empty() || detector_output.empty() || profile_prefix.empty() || run_onnx || run_gstreamer
            || run_yolo || run_video || run_video_check) {
            std::cerr << "Image detection requires an image, output and profile, without other modes\n";
            return 2;
        }
        return run_detector_image(base, detector_image, detector_output, detector_repeat_output, profile_prefix);
    }
    if (!run_onnx && !run_gstreamer && !run_yolo && !run_video && !run_video_check) {
        run_onnx = true;
        run_yolo = true;
    }

    std::cout << "Kataglyphis ONNX Runtime + GStreamer Inference Demo\n";
    std::cout << "==================================================\n\n";
    std::cout << "Model: " << model_path << "\n";
    std::cout << "Output layout: " << loaded->model.output_layout << "\n\n";

    int result = 0;

    if (run_onnx) {
        result = run_onnx_inference_example(base, profile_prefix);
        if (result != 0) {
            std::cerr << "ONNX inference example failed!\n";
            return result;
        }
    }

    if (run_gstreamer) {
        result = run_gstreamer_pipeline_example();
        if (result != 0) {
            std::cerr << "GStreamer pipeline example failed!\n";
            return result;
        }
    }

    if (run_yolo) {
        result = run_yolo_detection_example(base);
        if (result != 0) {
            std::cerr << "YOLO detection example failed!\n";
            return result;
        }
    }

    if (run_video) {
        result = run_video_detection_example(base);
        if (result != 0) {
            std::cerr << "Video detection example failed!\n";
            return result;
        }
    }

    if (run_video_check) {
        result = run_video_detection_check(base, profile_prefix);
        if (result != 0) { return result; }
    }

    std::cout << "\nAll examples completed successfully!\n";
    return 0;
}
