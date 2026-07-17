"""Smoke tests for the kataglyphis_inference Python bindings.

Run with the staged package on the path, e.g.:
    PYTHONPATH=<build-dir>/python python -m pytest Test/python -v
"""

import pytest

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
def test_onnx_uninitialized_inference_raises():
    np = pytest.importorskip("numpy")
    engine = ki.OnnxInferenceEngine()
    with pytest.raises(RuntimeError):
        engine.run_inference(np.zeros((1, 3, 640, 640), dtype=np.float32))


@needs_onnx
def test_session_config_defaults():
    cfg = ki.SessionConfig()
    assert cfg.intra_op_num_threads == 4
    assert cfg.execution_mode == ki.ExecutionMode.Sequential


@needs_onnx
def test_yolo_coco_class_name():
    assert ki.YoloDetector.get_coco_class_name(0) == "person"
