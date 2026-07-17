#include <nanobind/nanobind.h>
#include <nanobind/ndarray.h>
#include <nanobind/stl/filesystem.h>
#include <nanobind/stl/string.h>
#include <nanobind/stl/string_view.h>
#include <nanobind/stl/vector.h>

#include <cstddef>
#include <cstdint>
#include <expected>
#include <format>
#include <memory>
#include <span>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

import kataglyphis.inference;
import kataglyphis.config_loader;
#if HAS_ONNXRUNTIME
import kataglyphis.onnx_inference;
import kataglyphis.yolo_detector;
#endif

namespace nb = nanobind;
using namespace nb::literals;

namespace {

auto config_error_name(kataglyphis::config::ConfigError error) -> const char *
{
    using kataglyphis::config::ConfigError;
    switch (error) {
    case ConfigError::FileNotFound:
        return "FileNotFound";
    case ConfigError::ParseError:
        return "ParseError";
    case ConfigError::MissingField:
        return "MissingField";
    case ConfigError::InvalidValue:
        return "InvalidValue";
    }
    return "UnknownError";
}

template<typename T>
auto unwrap_config(std::expected<T, kataglyphis::config::ConfigError> &&result, const char *context) -> T
{
    if (!result) {
        throw std::invalid_argument(std::format("{} failed: {}", context, config_error_name(result.error())));
    }
    return std::move(*result);
}

#if HAS_ONNXRUNTIME

auto onnx_error_name(kataglyphis::inference::OnnxError error) -> const char *
{
    using kataglyphis::inference::OnnxError;
    switch (error) {
    case OnnxError::SessionCreationFailed:
        return "SessionCreationFailed";
    case OnnxError::ModelLoadFailed:
        return "ModelLoadFailed";
    case OnnxError::InputAllocationFailed:
        return "InputAllocationFailed";
    case OnnxError::OutputAllocationFailed:
        return "OutputAllocationFailed";
    case OnnxError::InferenceFailed:
        return "InferenceFailed";
    case OnnxError::InvalidInputShape:
        return "InvalidInputShape";
    case OnnxError::InvalidInputType:
        return "InvalidInputType";
    case OnnxError::MemoryAllocationError:
        return "MemoryAllocationError";
    case OnnxError::SessionNotInitialized:
        return "SessionNotInitialized";
    case OnnxError::OutputNotFound:
        return "OutputNotFound";
    }
    return "UnknownError";
}

[[noreturn]] void raise_onnx(const char *context, kataglyphis::inference::OnnxError error)
{
    throw std::runtime_error(std::format("{} failed: {}", context, onnx_error_name(error)));
}

using CpuFloatArray = nb::ndarray<const float, nb::c_contig, nb::device::cpu>;

auto shape_from_array(const CpuFloatArray &array) -> kataglyphis::inference::TensorShape
{
    kataglyphis::inference::TensorShape shape;
    shape.dimensions.reserve(array.ndim());
    for (std::size_t i = 0; i < array.ndim(); ++i) { shape.dimensions.push_back(array.shape(i)); }
    return shape;
}

// Hand the tensor's storage to NumPy without copying: the vector moves to the
// heap and a capsule deletes it once the last array reference dies.
auto tensor_to_numpy(kataglyphis::inference::TensorData &&tensor) -> nb::ndarray<nb::numpy, float>
{
    auto data = std::make_unique<std::vector<float>>(std::move(tensor.data));
    std::vector<std::size_t> shape = tensor.shape.dimensions;
    if (shape.empty()) { shape.push_back(data->size()); }
    nb::capsule owner(data.get(), [](void *ptr) noexcept { delete static_cast<std::vector<float> *>(ptr); });
    float *raw = data->data();
    data.release();
    return { raw, shape.size(), shape.data(), owner };
}

struct PyInferenceResult
{
    std::vector<nb::object> outputs;
    double inference_time_ms{};
};

auto make_py_result(kataglyphis::inference::InferenceResult &&result) -> PyInferenceResult
{
    PyInferenceResult converted;
    converted.inference_time_ms = result.inference_time_ms;
    converted.outputs.reserve(result.outputs.size());
    for (auto &tensor : result.outputs) { converted.outputs.push_back(nb::cast(tensor_to_numpy(std::move(tensor)))); }
    return converted;
}

void bind_onnx(nb::module_ &m)
{
    using namespace kataglyphis::inference;

    nb::enum_<OnnxError>(m, "OnnxError")
      .value("SessionCreationFailed", OnnxError::SessionCreationFailed)
      .value("ModelLoadFailed", OnnxError::ModelLoadFailed)
      .value("InputAllocationFailed", OnnxError::InputAllocationFailed)
      .value("OutputAllocationFailed", OnnxError::OutputAllocationFailed)
      .value("InferenceFailed", OnnxError::InferenceFailed)
      .value("InvalidInputShape", OnnxError::InvalidInputShape)
      .value("InvalidInputType", OnnxError::InvalidInputType)
      .value("MemoryAllocationError", OnnxError::MemoryAllocationError)
      .value("SessionNotInitialized", OnnxError::SessionNotInitialized)
      .value("OutputNotFound", OnnxError::OutputNotFound);

    nb::enum_<ExecutionMode>(m, "ExecutionMode")
      .value("Sequential", ExecutionMode::Sequential)
      .value("Parallel", ExecutionMode::Parallel);

    nb::class_<SessionConfig>(m, "SessionConfig")
      .def(nb::init<>())
      .def_rw("model_path", &SessionConfig::model_path)
      .def_rw("intra_op_num_threads", &SessionConfig::intra_op_num_threads)
      .def_rw("inter_op_num_threads", &SessionConfig::inter_op_num_threads)
      .def_rw("enable_cuda", &SessionConfig::enable_cuda)
      .def_rw("enable_memory_pattern", &SessionConfig::enable_memory_pattern)
      .def_rw("execution_mode", &SessionConfig::execution_mode);

    m.def("default_session_config", &create_default_session_config, "model_path"_a,
      "Create a SessionConfig with sensible defaults for the given model.");

    nb::class_<PyInferenceResult>(m, "InferenceResult")
      .def_ro("outputs", &PyInferenceResult::outputs, "List of NumPy arrays, one per model output.")
      .def_ro("inference_time_ms", &PyInferenceResult::inference_time_ms);

    nb::class_<OnnxInferenceEngine>(m, "OnnxInferenceEngine")
      .def(nb::init<>())
      .def(
        "initialize",
        [](OnnxInferenceEngine &self, const SessionConfig &config) {
            auto result = self.initialize(config);
            if (!result) { raise_onnx("initialize", result.error()); }
        },
        "config"_a)
      .def("is_initialized", &OnnxInferenceEngine::is_initialized)
      .def(
        "run_inference",
        [](OnnxInferenceEngine &self, const CpuFloatArray &input, const std::string &input_name) {
            const auto shape = shape_from_array(input);
            const std::span<const float> data(input.data(), input.size());
            std::expected<InferenceResult, OnnxError> result;
            {
                nb::gil_scoped_release release;
                result = self.run_inference(data, shape, input_name);
            }
            if (!result) { raise_onnx("run_inference", result.error()); }
            return make_py_result(std::move(*result));
        },
        "input"_a, "input_name"_a = "input",
        "Run inference on a float32 array; shape is taken from the array. Releases the GIL while running.")
      .def(
        "run_inference_multi_input",
        [](OnnxInferenceEngine &self, const nb::dict &inputs) {
            std::vector<std::pair<std::string, TensorData>> converted;
            converted.reserve(inputs.size());
            for (auto [key, value] : inputs) {
                auto array = nb::cast<CpuFloatArray>(value);
                TensorData tensor;
                tensor.shape = shape_from_array(array);
                tensor.data.assign(array.data(), array.data() + array.size());
                converted.emplace_back(nb::cast<std::string>(key), std::move(tensor));
            }
            std::expected<InferenceResult, OnnxError> result;
            {
                nb::gil_scoped_release release;
                result = self.run_inference_multi_input(converted);
            }
            if (!result) { raise_onnx("run_inference_multi_input", result.error()); }
            return make_py_result(std::move(*result));
        },
        "inputs"_a, "Run inference with a dict mapping input names to float32 arrays.")
      .def("get_input_names", &OnnxInferenceEngine::get_input_names)
      .def("get_output_names", &OnnxInferenceEngine::get_output_names)
      .def(
        "get_input_shape",
        [](const OnnxInferenceEngine &self, const std::string &name) {
            auto result = self.get_input_shape(name);
            if (!result) { raise_onnx("get_input_shape", result.error()); }
            return result->dimensions;
        },
        "name"_a)
      .def(
        "get_output_shape",
        [](const OnnxInferenceEngine &self, const std::string &name) {
            auto result = self.get_output_shape(name);
            if (!result) { raise_onnx("get_output_shape", result.error()); }
            return result->dimensions;
        },
        "name"_a);
}

void bind_yolo(nb::module_ &m)
{
    using namespace kataglyphis::detection;

    nb::class_<BoundingBox>(m, "BoundingBox")
      .def(nb::init<>())
      .def_rw("x", &BoundingBox::x)
      .def_rw("y", &BoundingBox::y)
      .def_rw("width", &BoundingBox::width)
      .def_rw("height", &BoundingBox::height)
      .def_rw("confidence", &BoundingBox::confidence)
      .def_rw("class_id", &BoundingBox::class_id)
      .def_rw("class_name", &BoundingBox::class_name)
      .def("__repr__", [](const BoundingBox &box) {
          return std::format("BoundingBox(x={}, y={}, width={}, height={}, confidence={:.3f}, class='{}')",
            box.x, box.y, box.width, box.height, box.confidence, box.class_name);
      });

    nb::class_<DetectionResult>(m, "DetectionResult")
      .def_ro("boxes", &DetectionResult::boxes)
      .def_ro("class_confidences", &DetectionResult::class_confidences)
      .def_ro("inference_time_ms", &DetectionResult::inference_time_ms)
      .def_ro("original_width", &DetectionResult::original_width)
      .def_ro("original_height", &DetectionResult::original_height);

    nb::class_<YoloConfig>(m, "YoloConfig")
      .def(nb::init<>())
      .def_rw("model_path", &YoloConfig::model_path)
      .def_rw("confidence_threshold", &YoloConfig::confidence_threshold)
      .def_rw("nms_threshold", &YoloConfig::nms_threshold)
      .def_rw("input_width", &YoloConfig::input_width)
      .def_rw("input_height", &YoloConfig::input_height)
      .def_rw("num_classes", &YoloConfig::num_classes);

    nb::class_<YoloDetector>(m, "YoloDetector")
      .def(nb::init<>())
      .def(
        "initialize",
        [](YoloDetector &self, const YoloConfig &config) {
            auto result = self.initialize(config);
            if (!result) { raise_onnx("YoloDetector.initialize", result.error()); }
        },
        "config"_a)
      .def("is_initialized", &YoloDetector::is_initialized)
      .def(
        "detect",
        [](YoloDetector &self, const CpuFloatArray &image, std::uint32_t width, std::uint32_t height) {
            // Infer width/height from an (H, W) or (H, W, C) array when not given.
            if (width == 0 && height == 0 && image.ndim() >= 2) {
                height = static_cast<std::uint32_t>(image.shape(0));
                width = static_cast<std::uint32_t>(image.shape(1));
            }
            const std::span<const float> data(image.data(), image.size());
            std::expected<DetectionResult, OnnxError> result;
            {
                nb::gil_scoped_release release;
                result = self.detect(data, width, height);
            }
            if (!result) { raise_onnx("detect", result.error()); }
            return std::move(*result);
        },
        "image"_a, "width"_a = 0, "height"_a = 0,
        "Detect objects in a float32 image. Width/height default to the array's (H, W) shape. Releases the GIL.")
      .def_static("get_coco_class_name", &YoloDetector::get_coco_class_name, "class_id"_a);
}

#endif// HAS_ONNXRUNTIME

void bind_config(nb::module_ &m)
{
    using namespace kataglyphis::config;

    nb::enum_<ConfigError>(m, "ConfigError")
      .value("FileNotFound", ConfigError::FileNotFound)
      .value("ParseError", ConfigError::ParseError)
      .value("MissingField", ConfigError::MissingField)
      .value("InvalidValue", ConfigError::InvalidValue);

    nb::class_<VideoConfig>(m, "VideoConfig")
      .def(nb::init<>())
      .def_rw("default_width", &VideoConfig::default_width)
      .def_rw("default_height", &VideoConfig::default_height)
      .def_rw("default_framerate", &VideoConfig::default_framerate)
      .def_rw("default_bitrate_kbps", &VideoConfig::default_bitrate_kbps);

    nb::class_<TextureConfig>(m, "TextureConfig")
      .def(nb::init<>())
      .def_rw("width", &TextureConfig::width)
      .def_rw("height", &TextureConfig::height);

    nb::class_<AndroidConfig>(m, "AndroidConfig")
      .def(nb::init<>())
      .def_rw("width", &AndroidConfig::width)
      .def_rw("height", &AndroidConfig::height)
      .def_rw("fps", &AndroidConfig::fps);

    nb::class_<StreamSettingsConfig>(m, "StreamSettingsConfig")
      .def(nb::init<>())
      .def_rw("source", &StreamSettingsConfig::source)
      .def_rw("encoder", &StreamSettingsConfig::encoder)
      .def_rw("device", &StreamSettingsConfig::device)
      .def_rw("camera_id", &StreamSettingsConfig::camera_id)
      .def_rw("input_path", &StreamSettingsConfig::input_path)
      .def_rw("input_uri", &StreamSettingsConfig::input_uri)
      .def_rw("peer_id", &StreamSettingsConfig::peer_id)
      .def_rw("producer_id", &StreamSettingsConfig::producer_id);

    nb::class_<WebRTCConfig>(m, "WebRTCConfig")
      .def(nb::init<>())
      .def_rw("signaling_server_url", &WebRTCConfig::signaling_server_url)
      .def_rw("reconnection_timeout_ms", &WebRTCConfig::reconnection_timeout_ms)
      .def_rw("stun_servers", &WebRTCConfig::stun_servers)
      .def_rw("turn_servers", &WebRTCConfig::turn_servers)
      .def_rw("video", &WebRTCConfig::video)
      .def_rw("texture", &WebRTCConfig::texture)
      .def_rw("android", &WebRTCConfig::android)
      .def_rw("stream", &WebRTCConfig::stream);

    m.def(
      "load_webrtc_config",
      [](const std::filesystem::path &config_path) {
          return unwrap_config(load_webrtc_config(config_path), "load_webrtc_config");
      },
      "config_path"_a, "Load WebRTC configuration from a JSON file.");
    m.def(
      "parse_webrtc_config",
      [](const std::string &json_content) {
          return unwrap_config(parse_webrtc_config(json_content), "parse_webrtc_config");
      },
      "json_content"_a, "Parse WebRTC configuration from a JSON string.");
    m.def("get_default_webrtc_config", &get_default_webrtc_config,
      "Get the default WebRTC configuration.");
}

}// namespace

NB_MODULE(_core, m)
{
    m.doc() = "Python bindings for the Kataglyphis C++ ONNX inference engine";
    m.attr("__version__") = kataglyphis::inference::MyCalculator{}.version();
    m.attr("HAS_ONNXRUNTIME") = static_cast<bool>(HAS_ONNXRUNTIME);

    nb::class_<kataglyphis::inference::MyCalculator>(m, "MyCalculator")
      .def(nb::init<>())
      .def("add", &kataglyphis::inference::MyCalculator::add, "lhs"_a, "rhs"_a)
      .def("version", &kataglyphis::inference::MyCalculator::version);

    bind_config(m);
#if HAS_ONNXRUNTIME
    bind_onnx(m);
    bind_yolo(m);
#endif
}
