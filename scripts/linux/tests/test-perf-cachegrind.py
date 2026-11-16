#!/usr/bin/env python3
"""perf-cachegrind.py against a fake valgrind: per-iteration counts, the max(3 %, 3 x spread) limit and the 5-run rule."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "perf-cachegrind.py"
FAKE = """#!/usr/bin/env python3
import os, sys
args = dict(a.split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
bench = args["--benchmark_filter"].strip("^$")
iterations = int(args["--benchmark_min_time"].rstrip("x"))
if os.environ.get("FAKE_EXIT"):
    sys.exit(int(os.environ["FAKE_EXIT"]))
with open(args["--cachegrind-out-file"], "w") as out:
    out.write(f"summary: {1000000 + iterations * int(os.environ['FAKE_' + bench])}\\n")
"""


def record(run: int, preprocess: int, detect: int) -> dict[str, object]:
    return {"key": "x64-clang", "cpu_model": f"cpu {run}", "run_id": str(run),
            "counts": {"BM_PreprocessFrame": preprocess, "BM_DetectFrame": detect, "BM_OnnxRunInferenceInPlace": 5000}}


class PerfCachegrind(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.valgrind = self.work / "valgrind"
        self.valgrind.write_text(FAKE, encoding="utf-8")
        self.valgrind.chmod(0o755)
        self.baseline = self.work / "baseline.json"
        entry = {"BM_PreprocessFrame": {"instructions": 1000, "spread": 0.002},
                 "BM_DetectFrame": {"instructions": 100000, "spread": 0.02},
                 "BM_OnnxRunInferenceInPlace": {"instructions": 5000, "spread": 0.001}}
        self.baseline.write_text(json.dumps({"baselines": {"x64-clang": entry}}), encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_tool(self, preprocess: int, detect: int, *extra: str, **env: str) -> subprocess.CompletedProcess[str]:
        environment = {**os.environ, "FAKE_BM_PreprocessFrame": str(preprocess), "FAKE_BM_DetectFrame": str(detect),
                       "FAKE_BM_OnnxRunInferenceInPlace": "5000", **env}
        cmd = [sys.executable, str(TOOL), "--suite", "suite", "--key", "x64-clang", "--valgrind", str(self.valgrind),
               "--baseline", str(self.baseline), *extra]
        return subprocess.run(cmd, capture_output=True, text=True, check=False, env=environment)

    def test_counts_are_per_iteration_with_the_fixed_cost_removed(self) -> None:
        out = self.work / "rec.json"
        result = self.run_tool(1000, 100000, "--record", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(out.read_text())["counts"],
                         {"BM_PreprocessFrame": 1000, "BM_DetectFrame": 100000, "BM_OnnxRunInferenceInPlace": 5000})

    def test_the_three_percent_floor_holds_a_small_spread(self) -> None:
        self.assertEqual(self.run_tool(1030, 100000).returncode, 0)
        result = self.run_tool(1031, 100000)
        self.assertEqual(result.returncode, 1)
        self.assertIn("BM_PreprocessFrame over", result.stdout)

    def test_three_times_a_wider_spread_is_the_limit(self) -> None:
        self.assertEqual(self.run_tool(1000, 106000).returncode, 0)
        result = self.run_tool(1000, 106001)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=Instruction count regressed::BM_DetectFrame", result.stderr)

    def test_a_count_under_the_band_asks_for_a_new_baseline(self) -> None:
        # The same 3 % floor below: 970 passes, 969 is a speed-up the baseline has to take on.
        self.assertEqual(self.run_tool(970, 100000).returncode, 0)
        result = self.run_tool(969, 100000)
        self.assertEqual(result.returncode, 1)
        self.assertIn("BM_PreprocessFrame under", result.stdout)
        self.assertIn("re-record the baseline", result.stderr)
        # Three times the wider spread below as well.
        self.assertEqual(self.run_tool(1000, 94000).returncode, 0)
        self.assertEqual(self.run_tool(1000, 93999).returncode, 1)

    def test_a_key_without_baseline_records_only_unless_required(self) -> None:
        self.assertEqual(self.run_tool(9999, 999999, "--key", "arm64-gcc").returncode, 0)
        self.assertEqual(self.run_tool(9999, 999999, "--key", "arm64-gcc", "--require-baseline").returncode, 1)

    def test_a_benchmark_without_an_entry_warns_unless_required(self) -> None:
        entry = json.loads(self.baseline.read_text())["baselines"]["x64-clang"]
        del entry["BM_OnnxRunInferenceInPlace"]
        self.baseline.write_text(json.dumps({"baselines": {"x64-clang": entry}}), encoding="utf-8")
        result = self.run_tool(1000, 100000, FAKE_BM_OnnxRunInferenceInPlace="99999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BM_OnnxRunInferenceInPlace 99999 has no entry yet", result.stderr)
        # Where the key must have a baseline, so must each of its benchmarks.
        required = self.run_tool(1000, 100000, "--require-baseline", FAKE_BM_OnnxRunInferenceInPlace="99999")
        self.assertEqual(required.returncode, 1)
        self.assertIn("BM_OnnxRunInferenceInPlace 99999 has no entry;", required.stderr)

    def test_a_failed_benchmark_run_fails(self) -> None:
        result = self.run_tool(1000, 100000, FAKE_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited 1", result.stderr)

    def test_the_spread_needs_five_runs(self) -> None:
        paths = []
        for run, detect in enumerate((100, 101, 99, 100, 102), start=1):
            path = self.work / f"r{run}.json"
            path.write_text(json.dumps(record(run, 10, detect)), encoding="utf-8")
            paths.append(str(path))
        short = subprocess.run([sys.executable, str(TOOL), "--summarize", *paths[:4]], capture_output=True, text=True, check=False)
        self.assertNotEqual(short.returncode, 0)
        full = subprocess.run([sys.executable, str(TOOL), "--summarize", *paths], capture_output=True, text=True, check=False)
        entry = json.loads(full.stdout)["BM_DetectFrame"]
        self.assertEqual((entry["instructions"], entry["spread"]), (100, 0.03))
        self.assertEqual(entry["runs"][0], {"run_id": "1", "cpu_model": "cpu 1", "instructions": 100})


if __name__ == "__main__":
    unittest.main()
