"""TextGenerator on the hub's tiny GenAI model, written per run and never stored."""

import json
import pathlib
import subprocess
import sys
import threading

import pytest

ki = pytest.importorskip("kataglyphis_inference")

GENERATOR = (
    pathlib.Path(__file__).resolve().parents[2] / "third_party" / "ANTfrastructure" / "linux" / "scripts" / "lib"
    / "tiny-genai-model.py"
)


@pytest.fixture(scope="module")
def tiny_model(tmp_path_factory):
    out = tmp_path_factory.mktemp("tiny-genai") / "model"
    subprocess.run([sys.executable, "-I", str(GENERATOR), "--out", str(out)], check=True, capture_output=True)
    return out, json.loads((out / "fixture.json").read_text(encoding="utf-8"))


@pytest.fixture
def generator(tiny_model):
    loaded = ki.TextGenerator()
    loaded.initialize(tiny_model[0])
    return loaded


def budget(tokens):
    options = ki.GenerationOptions()
    options.max_new_tokens = tokens
    return options


def test_greedy_decoding_yields_the_fixture_continuation(generator, tiny_model):
    _, oracle = tiny_model
    result = generator.generate([("user", oracle["prompt"])], budget(len(oracle["continuation_ids"])))
    assert result.text == oracle["continuation"]
    assert result.tokens == oracle["continuation_ids"]
    assert result.prompt_tokens == len(oracle["prompt_ids"])
    assert result.finish_reason == ki.FinishReason.LENGTH
    assert result.decode_tokens_per_second > 0


def test_on_text_receives_every_piece_in_order(generator, tiny_model):
    _, oracle = tiny_model
    pieces = []
    generator.generate([("user", oracle["prompt"])], budget(len(oracle["continuation_ids"])), pieces.append)
    assert "".join(pieces) == oracle["continuation"]
    assert len(pieces) == len(oracle["continuation_ids"])


def test_a_raising_callback_cancels_and_raises_its_exception(generator, tiny_model):
    _, oracle = tiny_model
    seen = []

    def refuse(piece):
        seen.append(piece)
        raise ValueError("stop at the first piece")

    with pytest.raises(ValueError, match="stop at the first piece"):
        generator.generate([("user", oracle["prompt"])], budget(4), refuse)
    assert seen == [oracle["continuation"][0]]
    assert generator.generate([("user", oracle["prompt"])], budget(4)).text == oracle["continuation"]


def test_request_cancel_inside_the_callback_ends_after_one_token(generator, tiny_model):
    _, oracle = tiny_model
    result = generator.generate([("user", oracle["prompt"])], budget(4), lambda _piece: generator.request_cancel())
    assert result.finish_reason == ki.FinishReason.CANCELLED
    assert result.tokens == oracle["continuation_ids"][:1]


def test_failures_raise_with_the_core_message(tiny_model):
    fresh = ki.TextGenerator()
    assert not fresh.is_initialized()
    with pytest.raises(RuntimeError, match="not initialized"):
        fresh.generate([("user", "abc")])
    with pytest.raises(RuntimeError, match="model directory could not be loaded"):
        fresh.initialize(tiny_model[0] / "absent")


def test_one_generator_serves_many_threads(generator, tiny_model):
    _, oracle = tiny_model
    errors, texts = [], []
    barrier = threading.Barrier(8)

    def worker():
        try:
            barrier.wait()
            for _ in range(20):
                texts.append(generator.generate([("user", oracle["prompt"])], budget(4)).text)
        except BaseException as exc:  # noqa: BLE001 -- every failure is reported on the main thread
            errors.append(exc)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert not errors
    assert texts == [oracle["continuation"]] * 160
