"""One shared binding object hammered from several threads; on 3.14t they run in parallel."""

import sys
import sysconfig
import threading

import pytest
from onnx_models import relu_model, yolo_reshape_model

ki = pytest.importorskip("kataglyphis_inference")

THREADS = 8
ROUNDS = 200

needs_onnx = pytest.mark.skipif(not getattr(ki, "HAS_ONNXRUNTIME", False), reason="built without ONNX Runtime")


def run_threads(worker, count=THREADS):
    """Start COUNT workers at one barrier and re-raise the first exception any of them hit."""
    barrier = threading.Barrier(count)
    errors = []

    def body(index):
        try:
            barrier.wait()
            worker(index)
        except BaseException as exc:  # noqa: BLE001 -- every failure is reported on the main thread
            errors.append(exc)

    threads = [threading.Thread(target=body, args=(i,)) for i in range(count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if errors:
        raise errors[0]


@pytest.mark.skipif(not sysconfig.get_config_var("Py_GIL_DISABLED"), reason="not a free-threaded interpreter")
def test_import_keeps_the_gil_disabled():
    # The module is imported above; a module without Py_MOD_GIL_NOT_USED would have switched the GIL back on.
    assert sys._is_gil_enabled() is False  # noqa: SLF001 -- the documented free-threading probe


def test_config_fields_written_from_many_threads():
    cfg = ki.WebRTCConfig()
    values = [f"ws://host-{i}.example.org:{8000 + i}/{'x' * (i * 40)}" for i in range(THREADS)]

    def worker(index):
        for _ in range(ROUNDS):
            cfg.signaling_server_url = values[index]
            cfg.stun_servers = [values[index]] * 3
            assert cfg.signaling_server_url in values
            assert all(s in values for s in cfg.stun_servers)

    run_threads(worker)


@pytest.fixture
def relu_path(tmp_path):
    path = tmp_path / "relu.onnx"
    path.write_bytes(relu_model())
    return path


@needs_onnx
def test_run_inference_on_one_engine_from_many_threads(relu_path):
    np = pytest.importorskip("numpy")
    engine = ki.OnnxInferenceEngine()
    engine.initialize(ki.default_session_config(str(relu_path)))

    def worker(index):
        data = np.array([[-1.0, 2.0, -3.0, float(index)]], dtype=np.float32)
        for _ in range(ROUNDS):
            result = engine.run_inference(data, "X")
            np.testing.assert_array_equal(result.outputs[0], np.maximum(data, 0.0))

    run_threads(worker)


@needs_onnx
def test_reinitialize_while_other_threads_run(relu_path):
    np = pytest.importorskip("numpy")
    engine = ki.OnnxInferenceEngine()
    config = ki.default_session_config(str(relu_path))
    engine.initialize(config)

    def worker(index):
        data = np.array([[1.0, -2.0, 3.0, -4.0]], dtype=np.float32)
        for _ in range(ROUNDS // 4 if index == 0 else ROUNDS):
            if index == 0:
                engine.initialize(config)
                assert engine.get_input_names() == ["X"]
            else:
                result = engine.run_inference_multi_input({"X": data})
                np.testing.assert_array_equal(result.outputs[0], np.maximum(data, 0.0))

    run_threads(worker)


@needs_onnx
def test_detect_while_the_detector_is_reinitialized(tmp_path):
    np = pytest.importorskip("numpy")
    height, width, rows, values = 2, 6, 4, 9
    path = tmp_path / "yolo.onnx"
    path.write_bytes(yolo_reshape_model(height, width, rows, values))
    config = ki.YoloConfig()
    config.model_path = str(path)
    config.input_width, config.input_height, config.num_classes = width, height, values - 5
    detector = ki.YoloDetector()
    detector.initialize(config)

    raw = np.zeros((rows, values), dtype=np.float32)
    raw[0, :5] = [10.0, 10.0, 4.0, 4.0, 0.9]
    raw[0, 5 + 2] = 0.9
    image = raw.reshape(3, height, width)

    def worker(index):
        for _ in range(ROUNDS // 4 if index == 0 else ROUNDS):
            if index == 0:
                detector.initialize(config)
            else:
                result = detector.detect(image, width, height)
                assert [box.class_id for box in result.boxes] == [2]

    run_threads(worker)
