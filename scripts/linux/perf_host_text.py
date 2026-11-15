#!/usr/bin/env python3
"""One --perf-host Python binding run: a warmed greedy reply's figures, or a replayed chat's; it says nothing about quality of the text."""

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
# A fixed five-turn chat: each turn sends every earlier message again, as TextGenerator.generate takes them.
CHAT_TURNS = (
    PROMPT,
    "Give the grey cat a name.",
    "What does the black cat do when the grey one sleeps?",
    "Where do they go when it rains?",
    "End the story in one sentence.",
)
CHAT_REPEATS = 3


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


def chat(model: str) -> dict[str, float]:
    """Median time to first token of the first and the last turn of CHAT_TURNS, after one warming reply."""
    ki = importlib.import_module("kataglyphis_inference")
    generator = ki.TextGenerator()
    generator.initialize(pathlib.Path(model))
    options = ki.GenerationOptions()
    options.max_new_tokens = TOKENS
    options.temperature = 0.0
    generator.generate([("user", PROMPT)], options)
    first, last = [], []
    for _ in range(CHAT_REPEATS):
        messages: list[tuple[str, str]] = []
        ttfts = []
        for question in CHAT_TURNS:
            messages.append(("user", question))
            result = generator.generate(messages, options)
            ttfts.append(result.time_to_first_token_ms)
            messages.append(("assistant", result.text))
        first.append(ttfts[0])
        last.append(ttfts[-1])
    turn1, turn5 = statistics.median(first), statistics.median(last)
    return {"turn1_ttft_ms": turn1, "turn5_ttft_ms": turn5, "turn5_over_turn1": turn5 / turn1}


def main(argv: list[str] | None = None) -> int:
    """Print the shared prompt or budget, or one run's figures as the last stdout line."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", help="a GenAI model directory")
    ap.add_argument("--print-prompt", action="store_true")
    ap.add_argument("--print-tokens", action="store_true")
    ap.add_argument("--chat", action="store_true", help="replay CHAT_TURNS and time the first and the last turn")
    args = ap.parse_args(argv)
    if args.print_prompt:
        answer = PROMPT
    elif args.print_tokens:
        answer = str(TOKENS)
    else:
        answer = json.dumps(chat(args.model) if args.chat else run(args.model))
    sys.stdout.write(answer + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
