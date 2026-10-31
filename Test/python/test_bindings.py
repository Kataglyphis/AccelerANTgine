"""Smoke tests for the kataglyphis_inference Python bindings.

Run with the staged package on the path, e.g.:
    PYTHONPATH=<build-dir>/python python -m pytest Test/python -v
"""

import pytest
from onnx_models import yolo_reshape_model

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


@needs_onnx
def test_onnx_uninitialized_inference_raises():
    np = pytest.importorskip("numpy")
    engine = ki.OnnxInferenceEngine()
    with pytest.raises(RuntimeError):
        engine.run_inference(np.zeros((1, 3, 640, 640), dtype=np.float32))


@needs_onnx
def test_session_config_defaults():
    assert ki.ExecutionProvider.CPU is not ki.OnnxExecutionProvider.Cpu
    cfg = ki.SessionConfig()
    assert cfg.intra_op_num_threads == 4
    assert cfg.execution_mode == ki.ExecutionMode.Sequential
    assert cfg.execution_provider == ki.OnnxExecutionProvider.Cpu
    assert cfg.device_id == 0
    cfg.execution_provider = ki.OnnxExecutionProvider.MigraphX
    assert cfg.execution_provider == ki.OnnxExecutionProvider.MigraphX
    yolo = ki.YoloConfig()
    yolo.execution_provider = ki.OnnxExecutionProvider.DirectML
    yolo.device_id = 1
    assert yolo.execution_provider == ki.OnnxExecutionProvider.DirectML
    assert yolo.device_id == 1


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
