"""ModelANT's text-generation-v1 on the released SmolLM2-135M; ci-python-bindings.sh runs it by name after fetching llm.lock."""

import importlib
import json
import os
import pathlib

# Imported by name like the other suites, since only the installed wheel provides it, never the source tree.
ki = importlib.import_module("kataglyphis_inference")

CONTRACT = pathlib.Path(__file__).resolve().parents[2] / "third_party" / "ModelANT" / "contracts" / "text-generation-v1.json"
RELEASED_IDS = [504, 3575, 282, 4649, 314, 7042, 30, 2]


def test_capital_of_france_decodes_the_released_tokens():
    cases = json.loads(CONTRACT.read_text(encoding="utf-8"))["cases"]
    assert [case["name"] for case in cases] == ["capital-of-france"]
    case = cases[0]
    assert case["expected_ids"] == RELEASED_IDS
    generator = ki.TextGenerator()
    generator.initialize(pathlib.Path(os.environ["KATAGLYPHIS_TEXT_CONTRACT_MODEL"]))
    options = ki.GenerationOptions()
    options.max_new_tokens = case["max_new_tokens"]
    # Greedy decoding ignores it; a mutant that samples instead then fails the same way on every run.
    options.seed = 1
    result = generator.generate([(m["role"], m["content"]) for m in case["messages"]], options)
    assert result.tokens == RELEASED_IDS
    assert case["must_contain"] in result.text
    assert result.finish_reason == ki.FinishReason.STOP
