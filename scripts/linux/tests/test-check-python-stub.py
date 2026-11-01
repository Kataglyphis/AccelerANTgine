#!/usr/bin/env python3
"""check-python-stub.py against fixture wheels: a match passes, drift fails with a diff, a missing stub is an error."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "check-python-stub.py"
STUB = "__version__: str\n\nHAS_ONNXRUNTIME: bool = True\n"


class CheckPythonStub(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.tracked = self.work / "_core.pyi"
        self.tracked.write_text(STUB, encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def wheel(self, members: dict[str, str]) -> Path:
        path = self.work / "kataglyphis_inference-0-cp315-cp315-linux_x86_64.whl"
        with zipfile.ZipFile(path, "w") as archive:
            for name, text in members.items():
                archive.writestr(name, text)
        return path

    def run_tool(self, wheel: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(TOOL), str(wheel), "--tracked", str(self.tracked)],
                              capture_output=True, text=True, check=False)

    def test_matching_stub_passes(self) -> None:
        result = self.run_tool(self.wheel({"kataglyphis_inference/_core.pyi": STUB}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("matches", result.stdout)

    def test_drift_fails_with_a_diff(self) -> None:
        built = STUB.replace("HAS_ONNXRUNTIME: bool = True", "HAS_ONNXRUNTIME: bool = False")
        result = self.run_tool(self.wheel({"kataglyphis_inference/_core.pyi": built}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("+HAS_ONNXRUNTIME: bool = False", result.stdout)
        self.assertIn("-HAS_ONNXRUNTIME: bool = True", result.stdout)
        self.assertIn("stale", result.stdout)

    def test_whitespace_drift_fails(self) -> None:
        result = self.run_tool(self.wheel({"kataglyphis_inference/_core.pyi": STUB + "\n"}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_missing_stub_is_an_error(self) -> None:
        result = self.run_tool(self.wheel({"kataglyphis_inference/__init__.py": ""}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("carries no kataglyphis_inference/_core.pyi", result.stderr)


if __name__ == "__main__":
    unittest.main()
