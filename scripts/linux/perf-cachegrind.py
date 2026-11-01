#!/usr/bin/env python3
"""Instruction counts of BM_PreprocessFrame and BM_DetectFrame under cachegrind, against perf/cachegrind-baseline.json.
It does not see wall time, cache misses, threading, GPU providers or a benchmark outside BENCHES; see docs/source/development_workflow.rst."""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

BENCHES = ("BM_PreprocessFrame", "BM_DetectFrame")
# Two warm iterations apart: the first iteration's allocations and the session load cancel out.
LOW, HIGH = 2, 4
MIN_RUNS = 5
FLOOR = 0.03
SPREAD_FACTOR = 3.0


def cpu_model() -> str:
    """The lscpu model name the spread is recorded against."""
    out = subprocess.run(["lscpu"], capture_output=True, text=True, check=False).stdout
    for line in out.splitlines():
        if line.startswith("Model name:"):
            return line.split(":", 1)[1].strip()
    return platform.processor() or "unknown"


def summary_ir(path: Path) -> int:
    """The `summary:` Ir total of one cachegrind output file."""
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("summary:"):
            return int(line.split()[1])
    raise SystemExit(f"perf-cachegrind: {path} has no summary line")


def run_ir(valgrind: str, suite: Path, bench: str, iterations: int, work: Path) -> int:
    """Total Ir of one run of `bench` at exactly `iterations` iterations; a failed run is fatal."""
    out = work / f"{bench}-{iterations}.out"
    cmd = [valgrind, "--tool=cachegrind", "--cache-sim=no", f"--cachegrind-out-file={out}",
           str(suite), f"--benchmark_filter=^{bench}$", f"--benchmark_min_time={iterations}x"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(f"perf-cachegrind: {bench} exited {proc.returncode}:\n{proc.stderr[-2000:]}")
    return summary_ir(out)


def measure(valgrind: str, suite: Path) -> dict[str, int]:
    """Instructions per iteration of each benchmark in BENCHES."""
    counts = {}
    with tempfile.TemporaryDirectory() as tmp:
        for bench in BENCHES:
            low = run_ir(valgrind, suite, bench, LOW, Path(tmp))
            high = run_ir(valgrind, suite, bench, HIGH, Path(tmp))
            counts[bench] = (high - low) // (HIGH - LOW)
    return counts


def summarize(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """One baseline entry from at least MIN_RUNS recorded runs: the median and the relative spread."""
    if len(records) < MIN_RUNS:
        raise SystemExit(f"perf-cachegrind: {len(records)} recorded run(s); the spread needs at least {MIN_RUNS}")
    entry: dict[str, dict[str, Any]] = {}
    for bench in BENCHES:
        values = [int(r["counts"][bench]) for r in records]
        median = statistics.median(values)
        entry[bench] = {
            "instructions": int(median),
            "spread": (max(values) - min(values)) / median,
            "runs": [{"run_id": r["run_id"], "cpu_model": r["cpu_model"], "instructions": int(r["counts"][bench])}
                     for r in records],
        }
    return entry


def limit(baseline: dict[str, Any]) -> float:
    """The highest count that passes: max(3 %, 3 x the recorded spread) over the baseline."""
    allowance = max(FLOOR, SPREAD_FACTOR * float(baseline["spread"]))
    return int(baseline["instructions"]) * (1 + allowance)


def check(counts: dict[str, int], entry: dict[str, dict[str, Any]]) -> int:
    """1 when a benchmark exceeds its limit; each verdict is printed."""
    failed = 0
    for bench in BENCHES:
        ceiling = limit(entry[bench])
        base = int(entry[bench]["instructions"])
        verdict = "over" if counts[bench] > ceiling else "ok"
        print(f"perf-cachegrind: {bench} {verdict}: {counts[bench]} instructions, baseline {base}, "
              f"limit {int(ceiling)} ({(counts[bench] / base - 1) * 100:+.2f} %)")
        if verdict == "over":
            print(f"::error title=Instruction count regressed::{bench} {counts[bench]} > {int(ceiling)}", file=sys.stderr)
            failed = 1
    return failed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, help="the built perfTestSuite")
    parser.add_argument("--baseline", type=Path, default=Path("perf/cachegrind-baseline.json"))
    parser.add_argument("--key", help="the baseline's <arch>-<compiler> entry, for example x64-clang")
    parser.add_argument("--record", type=Path, help="write this run's counts and CPU model as JSON")
    parser.add_argument("--require-baseline", action="store_true", help="fail when the key has no baseline")
    parser.add_argument("--summarize", nargs="+", type=Path, metavar="RECORD",
                        help="print a baseline entry from recorded runs instead of measuring")
    parser.add_argument("--valgrind", default="valgrind")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.summarize:
        records = [json.loads(p.read_text(encoding="utf-8")) for p in args.summarize]
        print(json.dumps(summarize(records), indent=2, sort_keys=True))
        return 0
    if args.suite is None or not args.key:
        raise SystemExit("perf-cachegrind: --suite and --key are required to measure")
    counts = measure(args.valgrind, args.suite)
    record = {"key": args.key, "cpu_model": cpu_model(), "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
              "counts": counts}
    print(f"perf-cachegrind: {json.dumps(record, sort_keys=True)}")
    if args.record:
        args.record.parent.mkdir(parents=True, exist_ok=True)
        args.record.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    baselines = json.loads(args.baseline.read_text(encoding="utf-8")).get("baselines", {}) if args.baseline.is_file() else {}
    if args.key not in baselines:
        if args.require_baseline:
            print(f"::error title=No instruction-count baseline::{args.key} has no entry in {args.baseline}", file=sys.stderr)
            return 1
        print(f"perf-cachegrind: {args.key} has no baseline in {args.baseline}; recorded only")
        return 0
    return check(counts, baselines[args.key])


if __name__ == "__main__":
    sys.exit(main())
