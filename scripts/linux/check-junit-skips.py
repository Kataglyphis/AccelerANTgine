#!/usr/bin/env python3
"""Fail when a JUnit report is missing, unreadable, empty, or reports any skipped or not-run testcase.

Does not cover: tests that never reached a report, such as a filtered ctest or a crashed runner.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# ctest writes skipped, disabled and not-run tests as a status attribute beside or instead of <skipped>.
NOT_RUN_STATUSES = frozenset({"notrun", "disabled", "skipped"})


def skipped_cases(path: Path) -> tuple[int, list[str]]:
    """(testcases, names of the skipped ones) in one report; raises ValueError when it holds none."""
    root = ET.parse(path).getroot()
    cases = list(root.iter("testcase"))
    if not cases:
        raise ValueError(f"{path}: no <testcase> element")
    skipped = []
    for case in cases:
        status = case.get("status", "").lower()
        if case.find("skipped") is not None or status in NOT_RUN_STATUSES:
            skipped.append(f"{case.get('classname', '')}.{case.get('name', '')}".strip("."))
    return len(cases), skipped


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fail on a skipped, not-run or missing JUnit testcase.")
    parser.add_argument("reports", nargs="+", type=Path, help="JUnit XML files, every one required")
    args = parser.parse_args(argv)
    total, found, broken = 0, [], []
    for path in args.reports:
        try:
            count, skipped = skipped_cases(path)
        except (OSError, ET.ParseError, ValueError) as exc:
            broken.append(str(exc))
            continue
        total += count
        found += [f"{path}: {name}" for name in skipped]
    for line in broken:
        print(f"junit skip gate: unreadable report: {line}", file=sys.stderr)
    for line in found:
        print(f"junit skip gate: skipped: {line}", file=sys.stderr)
    print(f"junit skip gate: {len(args.reports)} report(s), {total} testcase(s), {len(found)} skipped")
    return 1 if broken or found else 0


if __name__ == "__main__":
    sys.exit(main())
