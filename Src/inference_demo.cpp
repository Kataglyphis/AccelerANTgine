#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>

import kataglyphis.onnx_inference;
import kataglyphis.gstreamer_pipeline;
import kataglyphis.yolo_detector;
import kataglyphis.project_config;

namespace inference = kataglyphis::inference;
namespace gstreamer = kataglyphis::gstreamer;
namespace detection = kataglyphis::detection;

void print_detection_results(const detection::DetectionResult &result)
{
    std::cout << "Detection Results:\n";
    std::cout << "  Inference time: " << result.inference_time_ms << " ms\n";
    std::cout << "  Original size: " << result.original_width << "x" << result.original_height << "\n";
    std::cout << "  Objects detected: " << result.boxes.size() << "\n\n";

    for (const auto &box : result.boxes) {
        std::cout << "  - " << box.class_name << " (confidence: " << (box.confidence * 100.0f) << "%)\n"
                  << "    Position: (" << box.x << ", " << box.y << ")\n"
                  << "    Size: " << box.width << "x" << box.height << "\n\n";
    }
}

int run_onnx_inference_example(const std::string &model_path)
{
    std::cout << "=== ONNX Runtime Inference Example ===\n\n";

    inference::OnnxInferenceEngine engine;

    auto config = inference::create_default_session_config(model_path);
    config.intra_op_num_threads = 4;
    config.inter_op_num_threads = 4;

    std::cout << "Initializing ONNX Runtime with model: " << model_path << "\n";

    auto init_result = engine.initialize(config);
    if (!init_result) {
        std::cerr << "Failed to initialize ONNX Runtime: " << static_cast<int>(init_result.error()) << "\n";
        return 1;
    }

    std::cout << "ONNX Runtime initialized successfully!\n\n";

    auto input_names = engine.get_input_names();
    auto output_names = engine.get_output_names();

    std::cout << "Model inputs:\n";
    for (const auto &name : input_names) {
        auto shape = engine.get_input_shape(name);
        if (shape) {
            std::cout << "  " << name << ": [";
            for (std::size_t i = 0; i < shape->dimensions.size(); ++i) {
                if (i > 0) std::cout << ", ";
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
                if (i > 0) std::cout << ", ";
                std::cout << shape->dimensions[i];
            }
            std::cout << "]\n";
        }
    }

    std::cout << "\nPerforming inference on dummy data...\n";

    inference::TensorShape input_shape;
    input_shape.dimensions = { 1, 3, 640, 640 };
    std::size_t total_elements = input_shape.total_elements();

    std::vector<float> dummy_input(total_elements, 0.5f);

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
            if (j > 0) std::cout << ", ";
            std::cout << output.shape.dimensions[j];
        }
        std::cout << "] (" << output.data.size() << " elements)\n";
    }

    return 0;
}

int run_gstreamer_pipeline_example()
{
    std::cout << "\n=== GStreamer Pipeline Example ===\n\n";

    auto init_result = gstreamer::GStreamerPipeline::initialize_gstreamer();
    if (!init_result) {
        std::cerr << "Failed to initialize GStreamer: " << static_cast<int>(init_result.error()) << "\n";
        return 1;
    }

    std::cout << "GStreamer initialized successfully!\n";

    gstreamer::GStreamerPipeline pipeline;

    gstreamer::PipelineConfig config;
    config.pipeline_description =
      "videotestsrc num-buffers=100 ! "
      "video/x-raw,width=640,height=480,framerate=30/1 ! "
      "videoconvert ! "
      "appsink name=test_sink emit-signals=true sync=false";

    std::cout << "Creating pipeline...\n";
    auto create_result = pipeline.create_pipeline(config);
    if (!create_result) {
        std::cerr << "Failed to create pipeline: " << static_cast<int>(create_result.error()) << "\n";
        return 1;
    }

    pipeline.set_buffer_callback([](const gstreamer::BufferInfo &buffer) {
        std::cout << "Received buffer: " << buffer.size << " bytes, " << buffer.metadata.width << "x"
                  << buffer.metadata.height << "\n";
    });

    std::cout << "Starting pipeline...\n";
    auto start_result = pipeline.start();
    if (!start_result) {
        std::cerr << "Failed to start pipeline: " << static_cast<int>(start_result.error()) << "\n";
        return 1;
    }

    std::cout << "Pipeline running! Processing 10 buffers...\n";

    for (int i = 0; i < 10; ++i) {
        auto sample = pipeline.pull_sample(1000);
        if (sample) { std::cout << "Sample " << i + 1 << ": " << sample->size << " bytes\n"; }
    }

    std::cout << "Stopping pipeline...\n";
    pipeline.stop();

    gstreamer::GStreamerPipeline::deinitialize_gstreamer();
    std::cout << "GStreamer example completed!\n";

    return 0;
}

int run_yolo_detection_example(const std::string &model_path)
{
    std::cout << "\n=== YOLO Detection Example ===\n\n";

    detection::YoloDetector detector;

    detection::YoloConfig config;
    config.model_path = model_path;
    config.input_width = 640;
    config.input_height = 640;
    config.confidence_threshold = 0.25f;
    config.nms_threshold = 0.45f;
    config.num_classes = 80;

    std::cout << "Initializing YOLO detector with model: " << model_path << "\n";

    auto init_result = detector.initialize(config);
    if (!init_result) {
        std::cerr << "Failed to initialize YOLO detector: " << static_cast<int>(init_result.error()) << "\n";
        return 1;
    }

    std::cout << "YOLO detector initialized successfully!\n\n";

    std::cout << "Performing detection on dummy image data...\n";

    std::size_t input_size = 3 * 640 * 640;
    std::vector<float> dummy_image(input_size, 0.5f);

    auto result = detector.detect(dummy_image, 640, 480);
    if (!result) {
        std::cerr << "Detection failed: " << static_cast<int>(result.error()) << "\n";
        return 1;
    }

    print_detection_results(*result);

    return 0;
}

int run_video_detection_example(const std::string &model_path)
{
    std::cout << "\n=== Video Detection Pipeline Example ===\n\n";

    auto pipeline_result = detection::create_video_detection_pipeline("test.mp4", model_path, 640, 480);

    if (!pipeline_result) {
        std::cout << "Video detection pipeline creation failed (expected - no test.mp4)\n";
        std::cout << "In a real scenario, provide a valid video source.\n";
        return 0;
    }

    pipeline_result->set_detection_callback(
      [](const detection::DetectionResult &result, const gstreamer::BufferInfo &buffer) {
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

    pipeline_result->stop();
    std::cout << "Video detection completed!\n";

    return 0;
}

void print_usage(const char *program_name)
{
    std::cout << "Usage: " << program_name << " [options]\n\n"
              << "Options:\n"
              << "  --model <path>     Path to ONNX model (default: models/yolo26n.onnx)\n"
              << "  --onnx-only        Run only ONNX inference example\n"
              << "  --gstreamer-only   Run only GStreamer pipeline example\n"
              << "  --yolo-only        Run only YOLO detection example\n"
              << "  --all              Run all examples\n"
              << "  --help             Show this help message\n\n"
              << "Examples:\n"
              << "  " << program_name << " --model models/yolo26n.onnx --all\n"
              << "  " << program_name << " --onnx-only\n";
}

int main(int argc, char *argv[])
{
    std::string model_path = "models/yolo26n.onnx";
    bool run_onnx = false;
    bool run_gstreamer = false;
    bool run_yolo = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "--model" && i + 1 < argc) {
            model_path = argv[++i];
        } else if (arg == "--onnx-only") {
            run_onnx = true;
        } else if (arg == "--gstreamer-only") {
            run_gstreamer = true;
        } else if (arg == "--yolo-only") {
            run_yolo = true;
        } else if (arg == "--all") {
            run_onnx = true;
            run_gstreamer = true;
            run_yolo = true;
        } else if (arg == "--help") {
            print_usage(argv[0]);
            return 0;
        }
    }

    if (!run_onnx && !run_gstreamer && !run_yolo) {
        run_onnx = true;
        run_yolo = true;
    }

    std::cout << "Kataglyphis ONNX Runtime + GStreamer Inference Demo\n";
    std::cout << "==================================================\n\n";
    std::cout << "Model: " << model_path << "\n\n";

    int result = 0;

    if (run_onnx) {
        result = run_onnx_inference_example(model_path);
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
        result = run_yolo_detection_example(model_path);
        if (result != 0) {
            std::cerr << "YOLO detection example failed!\n";
            return result;
        }
    }

    std::cout << "\nAll examples completed successfully!\n";
    return 0;
}