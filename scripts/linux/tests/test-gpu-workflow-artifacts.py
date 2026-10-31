#!/usr/bin/env python3
"""Check candidate artifacts survive partial and full workflow reruns."""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LINUX = ROOT / ".github/workflows/linux-gpu-candidate.yml"
WINDOWS = ROOT / ".github/workflows/windows-gpu-candidates.yml"
SCOPE = ROOT / "scripts/linux/gpu-invocation-scope.py"


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


def expand(
    template: str, vendor: str, arch: str, attempt: int, suffix: str = ""
) -> str:
    for key, value in {
        "matrix.vendor": vendor,
        "matrix.arch": arch,
        "github.run_id": "42",
        "github.run_attempt": str(attempt),
        "needs.scope.outputs.suffix": suffix,
        "needs.preflight.outputs.suffix": suffix,
    }.items():
        template = template.replace("${{ " + key + " }}", value)
    return template


class ArtifactReruns(unittest.TestCase):
    def test_scope_validation_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = {**os.environ, "GITHUB_OUTPUT": str(output)}
            for value, expected in (
                ("default", "suffix=\n"),
                ("job-a", "suffix=-scope-job-a\n"),
                ("a" * 32, "suffix=-scope-" + "a" * 32 + "\n"),
            ):
                output.unlink(missing_ok=True)
                result = subprocess.run(
                    [sys.executable, "-I", str(SCOPE)],
                    env={**env, "GPU_INVOCATION_SCOPE": value},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(encoding="utf-8"), expected)
            for value in ("", "A", "-a", "a" * 33, "a/b", "x\nname=evil", "$(id)"):
                output.unlink(missing_ok=True)
                result = subprocess.run(
                    [sys.executable, "-I", str(SCOPE)],
                    env={**env, "GPU_INVOCATION_SCOPE": value},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0, value)
                self.assertFalse(output.exists(), value)

    def test_each_invocation_scopes_all_artifacts_and_concurrency(self):
        for workflow, dependency in (
            (LINUX, "needs.scope.outputs.suffix"),
            (WINDOWS, "needs.preflight.outputs.suffix"),
        ):
            text = workflow.read_text(encoding="utf-8")
            has_promotion = workflow == LINUX and "\n  stage-verified:\n" in text
            jobs = (
                ("build", "clean-host", "gpu-profile", "stage-verified")
                if has_promotion
                else ("build", "clean-host", "gpu-profile")
                if workflow == LINUX
                else ("candidate", "gpu-profile")
            )
            count = 14 if has_promotion else 3 if workflow == LINUX else 2
            trigger = text.split("\npermissions:", 1)[0]
            self.assertEqual(trigger.count("      invocation-scope:"), 2)
            self.assertEqual(trigger.count("        default: default"), 2)
            self.assertIn("GPU_INVOCATION_SCOPE: ${{ inputs.invocation-scope }}", text)
            self.assertIn("scripts/linux/gpu-invocation-scope.py", text)
            self.assertIn("suffix: ${{ steps.scope.outputs.suffix }}", text)
            artifacts = [
                line
                for line in text.splitlines()
                if re.match(
                    r"\s+(?:name|artifact): (?:accelerantgine-unverified-gpu-|unverified-accelerantgine-|verified-accelerantgine-)",
                    line,
                )
            ]
            self.assertEqual(len(artifacts), count)
            suffix = "${{ " + dependency + " }}"
            groups = []
            for job in jobs:
                body = text.split(f"\n  {job}:\n", 1)[1]
                body = re.split(r"(?m)^  [a-z][a-z0-9-]*:\n", body, maxsplit=1)[0]
                group = re.search(r"(?m)^      group: (.+)$", body)
                self.assertIsNotNone(group, job)
                self.assertIn(suffix, group.group(1))
                self.assertIn("${{ matrix.vendor }}", group.group(1))
                self.assertNotIn("${{ inputs.invocation-scope }}", group.group(1))
                self.assertIn("cancel-in-progress:", body)
                self.assertNotEqual(
                    expand(group.group(1), "amd", "x64", 1, "-scope-first"),
                    expand(group.group(1), "amd", "x64", 1, "-scope-second"),
                )
                groups.append(group.group(1))
            self.assertEqual(len(groups), len(set(groups)))
            for line in artifacts:
                with self.subTest(workflow=workflow.name, artifact=line):
                    self.assertIn(suffix, line)
                    self.assertIn("${{ github.run_attempt }}", line)
            prefixes = (
                {
                    "accelerantgine-unverified-gpu-": 3,
                    "unverified-accelerantgine-gpu-input-": 2,
                    "unverified-accelerantgine-gpu-meta-": 4,
                    "unverified-accelerantgine-gpu-clean-": 2,
                    "unverified-accelerantgine-gpu-profile-": 2,
                    "verified-accelerantgine-linux-": 1,
                }
                if has_promotion
                else {"accelerantgine-unverified-gpu-": 3}
                if workflow == LINUX
                else {"unverified-accelerantgine-windows-x64-": 2}
            )
            for prefix, references in prefixes.items():
                names = [line.split(": ", 1)[1] for line in artifacts if prefix in line]
                self.assertEqual(len(names), references, prefix)
                self.assertEqual(len(set(names)), 1, prefix)
                name = names[0]
                self.assertNotEqual(
                    expand(name, "nvidia", "x64", 1, "-scope-all"),
                    expand(name, "nvidia", "x64", 1, "-scope-single"),
                )
            for line in text.splitlines():
                if (
                    "path:" in line or "CANDIDATE_DIR:" in line
                ) and "/accelerantgine-gpu-" in line:
                    self.assertIn(suffix, line)
        self.assertIn(
            "needs: [preflight, candidate]", WINDOWS.read_text(encoding="utf-8")
        )

    def test_workflows_can_be_called_without_cancelling_their_caller(self):
        for workflow in (LINUX, WINDOWS):
            text = workflow.read_text(encoding="utf-8")
            call = text.split("  workflow_call:\n", 1)[1].split("\npermissions:", 1)[0]
            self.assertRegex(
                call,
                r"(?ms)^      verify-gpu:\n        type: boolean\n        default: false$",
            )
            self.assertRegex(call, r"(?ms)^      GHCR_PAT:\n        required: false$")
            groups = re.findall(r"(?m)^      group: (accelerantgine-.+)$", text)
            self.assertTrue(groups)
            self.assertTrue(all("${{ github.workflow }}" in group for group in groups))
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
                        .replace("${{ needs.scope.outputs.suffix }}", "")
                        .replace("${{ needs.preflight.outputs.suffix }}", "")
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
        self.assertNotEqual(
            expand(name, "nvidia", "x64", 1, "-scope-all"),
            expand(name, "nvidia", "x64", 1, "-scope-single"),
        )
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
        self.assertNotEqual(
            expand(name, "amd", "x64", 1, "-scope-first"),
            expand(name, "amd", "x64", 1, "-scope-second"),
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
