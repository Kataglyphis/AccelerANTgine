#!/usr/bin/env python3
"""Check candidate artifacts survive partial and full workflow reruns."""

import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LINUX = ROOT / ".github/workflows/linux-gpu-candidate.yml"
WINDOWS = ROOT / ".github/workflows/windows-gpu-candidates.yml"


def contract(text: str, prefix: str, references: int) -> str:
    names = re.findall(
        r"(?m)^\s+(?:name|artifact): (" + re.escape(prefix) + r"[^\n]+)$", text
    )
    if len(names) != references or len(set(names)) != 1:
        raise ValueError("upload and download artifact names differ")
    template = names[0]
    if "${{ github.run_attempt }}" not in template:
        raise ValueError("candidate artifacts must be scoped to the current attempt")
    upload = re.search(
        r"(?ms)uses: actions/upload-artifact@[^\n]+\n\s+with:\n(.*?)(?=^\s+- name:|^  [\w-]+:|\Z)",
        text,
    )
    if not upload or "overwrite: false" not in upload.group(1):
        raise ValueError("candidate artifacts must not replace earlier uploads")
    return template


def expand(template: str, vendor: str, arch: str, attempt: int) -> str:
    for key, value in {
        "matrix.vendor": vendor,
        "matrix.arch": arch,
        "github.run_id": "42",
        "github.run_attempt": str(attempt),
    }.items():
        template = template.replace("${{ " + key + " }}", value)
    return template


class ArtifactReruns(unittest.TestCase):
    def test_workflows_can_be_called_without_cancelling_their_caller(self):
        for workflow in (LINUX, WINDOWS):
            text = workflow.read_text(encoding="utf-8")
            call = text.split("  workflow_call:\n", 1)[1].split("\npermissions:", 1)[0]
            self.assertRegex(
                call,
                r"(?ms)^      verify-gpu:\n        type: boolean\n        default: false$",
            )
            self.assertRegex(call, r"(?ms)^      GHCR_PAT:\n        required: false$")
            self.assertIn(
                "${{ github.workflow }}",
                text.split("\nconcurrency:\n", 1)[1].split("\njobs:", 1)[0],
            )
            if workflow == WINDOWS:
                self.assertRegex(
                    call,
                    r"(?ms)^      amd-device-index:\n        type: string\n        default: '0'$",
                )

    def test_profile_downloads_ignore_stale_candidates(self):
        for workflow, reference in (
            (LINUX, '"$CANDIDATE_DIR"'),
            (WINDOWS, "$env:CANDIDATE_DIR"),
        ):
            job = workflow.read_text(encoding="utf-8").split("\n  gpu-profile:\n", 1)[1]
            destination = re.search(r"(?m)^\s+path: (.+)$", job).group(1)
            used = re.search(r"(?m)^\s+CANDIDATE_DIR: (.+)$", job).group(1)
            self.assertEqual(destination, used)
            self.assertIn(reference, job)
            for key in ("github.run_id", "github.run_attempt", "matrix.vendor"):
                self.assertIn("${{ " + key + " }}", destination)
            if workflow == LINUX:
                self.assertIn("${{ matrix.arch }}", destination)
            with tempfile.TemporaryDirectory() as temp:

                def path(run, attempt, vendor, template=destination):
                    return Path(
                        template.replace("${{ runner.temp }}", temp)
                        .replace("${{ github.run_id }}", run)
                        .replace("${{ github.run_attempt }}", attempt)
                        .replace("${{ matrix.vendor }}", vendor)
                        .replace("${{ matrix.arch }}", "x64")
                    )

                stale, previous, current = (
                    path("1", "1", "amd"),
                    path("2", "1", "amd"),
                    path("2", "2", "amd"),
                )
                for directory in (stale, previous, current):
                    directory.mkdir()
                (stale / "old.zip").touch()
                (previous / "previous.zip").touch()
                (current / "current.zip").touch()
                self.assertEqual(
                    [p.name for p in current.glob("*.zip")], ["current.zip"]
                )
                self.assertNotEqual(current, path("2", "2", "nvidia"))

    def test_linux_partial_and_full_reruns(self):
        text = LINUX.read_text(encoding="utf-8")
        name = contract(text, "accelerantgine-unverified-gpu-", 3)
        rows = [("nvidia", "x64"), ("nvidia", "arm64"), ("amd", "x64")]
        first = {expand(name, vendor, arch, 1): "attempt-1" for vendor, arch in rows}
        self.assertEqual(len(first), len(rows))
        partial = [expand(name, vendor, arch, 2) for vendor, arch in rows]
        self.assertTrue(all(candidate not in first for candidate in partial))
        for candidate in partial:
            first[candidate] = "attempt-2"
        self.assertEqual(len(first), 2 * len(rows))
        self.assertEqual(list(first.values()).count("attempt-1"), len(rows))
        self.assertEqual(list(first.values()).count("attempt-2"), len(rows))
        with self.assertRaises(ValueError):
            contract(
                text.replace("overwrite: false", "overwrite: true", 1),
                "accelerantgine-unverified-gpu-",
                3,
            )
        with self.assertRaises(ValueError):
            contract(
                text.replace("-attempt-${{ github.run_attempt }}", ""),
                "accelerantgine-unverified-gpu-",
                3,
            )

    def test_windows_candidate_is_attempt_scoped_and_immutable(self):
        text = WINDOWS.read_text(encoding="utf-8")
        prefix = "unverified-accelerantgine-windows-x64-"
        name = contract(text, prefix, 2)
        self.assertNotEqual(
            expand(name, "amd", "x64", 1), expand(name, "amd", "x64", 2)
        )
        self.assertNotEqual(
            expand(name, "amd", "x64", 1), expand(name, "nvidia", "x64", 1)
        )
        for mutant in (
            text.replace("overwrite: false", "overwrite: true", 1),
            text.replace("-attempt-${{ github.run_attempt }}", ""),
            text.replace(name, name + "-different", 1),
        ):
            with self.assertRaises(ValueError):
                contract(mutant, prefix, 2)

    def test_windows_profiles_isolate_gstreamer_and_keep_gpu_runtime_path(self):
        job = WINDOWS.read_text(encoding="utf-8").split("\n  gpu-profile:\n", 1)[1]
        calls = [
            line for line in job.splitlines() if "Test-WindowsGpuCleanHost.ps1" in line
        ]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all("-PreserveGpuRuntimePath" in call for call in calls))
        self.assertTrue(any("'--onnx-only'" in call for call in calls))
        self.assertTrue(any("'--video-check'" in call for call in calls))
        onnx = next(call for call in calls if "'--onnx-only'" in call)
        video = next(call for call in calls if "'--video-check'" in call)
        self.assertNotIn("'--device',", onnx)
        self.assertIn("'--device', $env:DEVICE", video)


if __name__ == "__main__":
    unittest.main()
