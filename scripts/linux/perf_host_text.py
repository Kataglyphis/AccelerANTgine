#!/usr/bin/env python3
"""One --perf-host Python binding run: a warmed greedy reply's figures; it says nothing about quality of the text."""

from __future__ import annotations

import argparse
import importlib
import json
import pathlib
import statistics
import sys

PROMPT = "Tell a short story about two cats on a sofa."
TOKENS = 48
TIMED_REPLIES = 5


def run(model: str) -> dict[str, float]:
    """Median time to first token and decode rate of greedy replies, after one warming reply."""
    ki = importlib.import_module("kataglyphis_inference")
    generator = ki.TextGenerator()
    generator.initialize(pathlib.Path(model))
    options = ki.GenerationOptions()
    options.max_new_tokens = TOKENS
    options.temperature = 0.0
    messages = [("user", PROMPT)]
    generator.generate(messages, options)
    results = [generator.generate(messages, options) for _ in range(TIMED_REPLIES)]
    return {
        "ttft_ms": statistics.median(r.time_to_first_token_ms for r in results),
        "decode_tok_s": statistics.median(r.decode_tokens_per_second for r in results),
    }


def main(argv: list[str] | None = None) -> int:
    """Print the shared prompt or budget, or one run's figures as the last stdout line."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", help="a GenAI model directory")
    ap.add_argument("--print-prompt", action="store_true")
    ap.add_argument("--print-tokens", action="store_true")
    args = ap.parse_args(argv)
    if args.print_prompt:
        answer = PROMPT
    elif args.print_tokens:
        answer = str(TOKENS)
    else:
        answer = json.dumps(run(args.model))
    sys.stdout.write(answer + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
