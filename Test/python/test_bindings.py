"""Smoke tests for the kataglyphis_inference Python bindings.

Run with the staged package on the path, e.g.:
    PYTHONPATH=<build-dir>/python python -m pytest Test/python -v
"""

import pytest
from onnx_models import dynamic_relu_model, yolo_reshape_model

ki = pytest.importorskip("kataglyphis_inference")


def test_version():
    assert isinstance(ki.__version__, str)
    assert ki.__version__


def test_calculator_add():
    calc = ki.MyCalculator()
    assert calc.add(2, 3) == 5
    assert calc.add(-7, 7) == 0


def test_calculator_version_matches_module():
    assert ki.MyCalculator().version() == ki.__version__


def test_default_webrtc_config():
    cfg = ki.get_default_webrtc_config()
    assert cfg.video.default_width == 1280
    assert cfg.video.default_height == 720
    assert cfg.signaling_server_url.startswith("ws")


def test_webrtc_config_roundtrip_fields():
    cfg = ki.WebRTCConfig()
    cfg.signaling_server_url = "ws://example.org:1234"
    cfg.stun_servers = ["stun:stun.example.org:3478"]
    assert cfg.signaling_server_url == "ws://example.org:1234"
    assert cfg.stun_servers == ["stun:stun.example.org:3478"]


def test_parse_webrtc_config_invalid_raises():
    with pytest.raises((ValueError, RuntimeError)):
        ki.parse_webrtc_config("this is not json {")


def test_a_config_error_is_raised_under_the_name_of_its_code(tmp_path):
    """The text after the colon is the C++ to_string of the code, not a table the binding keeps."""
    with pytest.raises(ValueError, match=r"^load_webrtc_config failed: FileNotFound$"):
        ki.load_webrtc_config(str(tmp_path / "missing.json"))
    with pytest.raises(ValueError, match=r"^parse_webrtc_config failed: ParseError$"):
        ki.parse_webrtc_config("this is not json {")


needs_onnx = pytest.mark.skipif(
    not getattr(ki, "HAS_ONNXRUNTIME", False),
    reason="built without ONNX Runtime",
)


@needs_onnx
def test_onnx_engine_uninitialized():
    engine = ki.OnnxInferenceEngine()
    assert not engine.is_initialized()


@needs_onnx
def test_onnx_output_errors_are_exposed():
    """Python callers can distinguish unsupported output types from invalid output shapes."""
    assert ki.OnnxError.InvalidOutputType.name == "InvalidOutputType"
    assert ki.OnnxError.InvalidOutputShape.name == "InvalidOutputShape"
    assert ki.OnnxError.ProviderUnavailable.name == "ProviderUnavailable"
    # A late frame and the end of a stream, the last two values.
    assert (ki.OnnxError.FrameTimeout.value, ki.OnnxError.EndOfStream.value) == (15, 16)


@needs_onnx
def test_an_onnx_error_is_raised_under_the_name_python_gives_the_same_code():
    np = pytest.importorskip("numpy")
    with pytest.raises(RuntimeError, match=r"^run_inference failed: \w+$") as raised:
        ki.OnnxInferenceEngine().run_inference(np.zeros((1, 3, 640, 640), dtype=np.float32))
    name = str(raised.value).rsplit(": ", 1)[1]
    assert name == ki.OnnxError.SessionNotInitialized.name


@needs_onnx
def test_a_dynamic_dimension_is_none_and_a_fixed_one_its_size(tmp_path):
    """The getters cast ONNX Runtime's -1 to size_t, so Python saw 18446744073709551615 for a dynamic batch."""
    model = tmp_path / "dynamic.onnx"
    model.write_bytes(dynamic_relu_model())
    engine = ki.OnnxInferenceEngine()
    engine.initialize(ki.default_session_config(str(model)))
    assert engine.get_input_shape("X") == [None, 4]
    assert engine.get_output_shape("Y") == [None, 4]


def test_onnx_uninitialized_inference_raises():
    np = pytest.importorskip("numpy")
    engine = ki.OnnxInferenceEngine()
    with pytest.raises(RuntimeError):
        engine.run_inference(np.zeros((1, 3, 640, 640), dtype=np.float32))


@needs_onnx
def test_session_config_defaults():
    assert [p.name for p in ki.ExecutionProvider] == ["Cpu", "Cuda", "MigraphX", "DirectML", "Xnnpack", "Dnnl"]
    cfg = ki.SessionConfig()
    assert cfg.intra_op_num_threads == 4
    assert cfg.execution_mode == ki.ExecutionMode.Sequential
    assert cfg.execution_provider == ki.ExecutionProvider.Cpu
    assert cfg.device_id == 0
    cfg.execution_provider = ki.ExecutionProvider.MigraphX
    assert cfg.execution_provider == ki.ExecutionProvider.MigraphX
    yolo = ki.YoloConfig()
    yolo.execution_provider = ki.ExecutionProvider.DirectML
    yolo.device_id = 1
    assert yolo.execution_provider == ki.ExecutionProvider.DirectML
    assert yolo.device_id == 1
    for provider in (ki.ExecutionProvider.Xnnpack, ki.ExecutionProvider.Dnnl):
        yolo.execution_provider = provider
        assert yolo.execution_provider == provider
    yolo.output_layout = ki.YoloOutputLayout.Auto
    assert yolo.output_layout == ki.YoloOutputLayout.Auto
    yolo.output_layout = ki.YoloOutputLayout.CenterScoresByAnchor
    assert yolo.output_layout == ki.YoloOutputLayout.CenterScoresByAnchor


@needs_onnx
def test_yolo_coco_class_name():
    assert ki.YoloDetector.get_coco_class_name(0) == "person"


@needs_onnx
def test_yolo_end_to_end_rows_decode_using_selected_layout(tmp_path):
    np = pytest.importorskip("numpy")
    model = tmp_path / "detections.onnx"
    model.write_bytes(yolo_reshape_model(height=2, width=3, rows=3, values=6))
    config = ki.YoloConfig()
    assert config.output_layout == ki.YoloOutputLayout.CenterObjectnessScores
    config.model_path = model
    config.input_width, config.input_height = 3, 2
    config.output_layout = ki.YoloOutputLayout.CornersScoreClass
    detector = ki.YoloDetector()
    detector.initialize(config)

    rows = np.zeros((3, 6), dtype=np.float32)
    rows[0] = [0.25, 0.25, 2.75, 1.75, 0.8, 2.0]
    result = detector.detect(rows.reshape(3, 2, 3), width=3, height=2)
    assert len(result.boxes) == 1
    box = result.boxes[0]
    assert box.class_id == 2
    assert box.confidence == pytest.approx(0.8)
    assert (box.x, box.y, box.width, box.height) == pytest.approx((0.25, 0.25, 2.5, 1.5))

    image = rows.reshape(3, 2, 3)
    for array in (image, image[np.newaxis, ...]):
        inferred = detector.detect(array)
        assert (inferred.original_width, inferred.original_height) == (3, 2)
        box = inferred.boxes[0]
        assert (box.x, box.y, box.width, box.height) == pytest.approx((0.25, 0.25, 2.5, 1.5))

        scaled = detector.detect(array, width=6, height=4)
        assert (scaled.original_width, scaled.original_height) == (6, 4)
        box = scaled.boxes[0]
        assert (box.x, box.y, box.width, box.height) == pytest.approx((0.5, 0.5, 5.0, 3.0))

    for array in (np.zeros((2, 3, 3), dtype=np.float32), np.zeros((2, 3, 2, 3), dtype=np.float32)):
        with pytest.raises(ValueError, match="CHW or single-batch NCHW"):
            detector.detect(array, width=3, height=2)
    with pytest.raises(ValueError, match="width and height are required"):
        detector.detect(rows)
    with pytest.raises(ValueError, match="both be specified"):
        detector.detect(image, width=3)
    flattened = detector.detect(rows, width=3, height=2)
    assert flattened.boxes[0].class_id == 2
