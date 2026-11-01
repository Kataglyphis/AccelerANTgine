#!/usr/bin/env python3
"""Fail when a coverage summary's line or branch percentage is below its floor, or the summary lacks either.

Does not cover: which files the report measured; the caller's filters decide that.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def percent(covered: float, total: float, what: str) -> float:
    """covered/total as a percentage; a report without the counted kind is an error, never 0 %."""
    if total <= 0:
        raise ValueError(f"the report counts no {what}")
    return 100.0 * covered / total


def totals(doc: object) -> tuple[float, float]:
    """(line %, branch %) from an llvm-cov export or a gcovr --json-summary document."""
    if isinstance(doc, dict) and isinstance(doc.get("data"), list) and doc["data"]:
        sums = doc["data"][0]["totals"]
        return (percent(sums["lines"]["covered"], sums["lines"]["count"], "lines"),
                percent(sums["branches"]["covered"], sums["branches"]["count"], "branches"))
    if isinstance(doc, dict) and "line_total" in doc:
        return (percent(doc["line_covered"], doc["line_total"], "lines"),
                percent(doc["branch_covered"], doc["branch_total"], "branches"))
    raise ValueError("neither an llvm-cov export nor a gcovr --json-summary")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fail on a coverage figure below its floor.")
    parser.add_argument("report", type=Path)
    parser.add_argument("--min-lines", type=float, required=True)
    parser.add_argument("--min-branches", type=float, required=True)
    args = parser.parse_args(argv)
    try:
        lines, branches = totals(json.loads(args.report.read_text(encoding="utf-8")))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        print(f"coverage floor: unreadable report {args.report}: {exc}", file=sys.stderr)
        return 2
    print(f"coverage floor: lines {lines:.2f}% (minimum {args.min_lines:g}%), "
          f"branches {branches:.2f}% (minimum {args.min_branches:g}%)", flush=True)
    below = [f"{name} {value:.2f}% < {floor:g}%" for name, value, floor in
             (("lines", lines, args.min_lines), ("branches", branches, args.min_branches))
             if value < floor]
    if below:
        print(f"coverage floor: below the floor: {', '.join(below)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
