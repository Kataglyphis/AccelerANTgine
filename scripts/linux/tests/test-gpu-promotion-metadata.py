#!/usr/bin/env python3
"""Check matrix promotion metadata without GitHub or GPU hardware."""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/linux/gpu-promotion-metadata.py"
SELECT = ROOT / "scripts/linux/select-gpu-matrix.py"
WORKFLOW = ROOT / ".github/workflows/linux-gpu-candidate.yml"
HUB = "da0bdf709f491b900a9ed02c821d7cbc3a13c8be"


def promotion_contract(workflow):
    metadata = "unverified-accelerantgine-gpu-meta-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}${{ needs.scope.outputs.suffix }}"
    trigger = workflow.split("\npermissions:", 1)[0]
    dispatch = trigger.split("  workflow_dispatch:\n", 1)[-1].split(
        "  workflow_call:\n", 1
    )[0]
    call = trigger.split("  workflow_call:\n", 1)[-1]
    hardware = re.search(
        r"(?ms)^      - name: Require hardware checks for promotion\n(.*?)(?=^      - name:|\Z)",
        workflow,
    )
    preflight = workflow.split("name: Check pinned GPU packaging APIs", 1)[-1].split(
        "name: Select registry image", 1
    )[0]
    clean = workflow.split("\n  clean-host:\n", 1)[-1].split("\n  gpu-profile:\n", 1)[0]
    gpu = workflow.split("\n  gpu-profile:\n", 1)[-1].split("\n  stage-verified:\n", 1)[
        0
    ]
    stage = workflow.split("\n  stage-verified:\n", 1)[-1]
    clean_profile = re.search(
        r"(?ms)^      - name: Check immutable packages on the clean host\n(.*?)(?=^      - name:|\Z)",
        clean,
    )
    profile = re.search(
        r"(?ms)^      - name: Profile the immutable packages\n(.*?)(?=^      - name:|\Z)",
        gpu,
    )
    checks = (
        "if: ${{ inputs.promote-verified && !inputs.verify-gpu }}",
        "if: ${{ inputs.promote-verified && inputs.verify-gpu }}",
        "needs: [scope, select-tuple]",
        "needs: [scope, select-tuple, build]",
        "needs: [scope, select-tuple, build, clean-host]",
        "needs: [scope, select-tuple, build, clean-host, gpu-profile]",
        "artifact-ids: ${{ steps.metadata.outputs.artifact_id }}",
        "artifact-digest: ${{ steps.metadata.outputs.artifact_digest }}",
        "artifact-files: ${{ steps.metadata.outputs.files }}",
        "skip-decompress: true",
    )
    return (
        workflow.count(metadata) == 4
        and re.search(
            r"(?m)^      promote-verified:\n        description: [^\n]+\n        type: boolean\n        default: false$",
            dispatch,
        )
        is not None
        and "      promote-verified:\n        type: boolean\n        default: false"
        in call
        and hardware is not None
        and profile is not None
        and clean_profile is not None
        and "        if: ${{ inputs.promote-verified && !inputs.verify-gpu }}"
        in hardware.group(1).splitlines()
        and "          exit 1" in hardware.group(1).splitlines()
        and "continue-on-error" not in hardware.group(1)
        and "          set -euo pipefail" in preflight.splitlines()
        and workflow.count("gpu-promotion-metadata.py resolve ") == 3
        and workflow.count("matrix: ${{ fromJSON(needs.select-tuple.outputs.matrix) }}")
        == 4
        and "matrix: ${{ steps.matrix.outputs.matrix }}" in workflow
        and "GPU_TUPLE: ${{ inputs.gpu-tuple }}" in workflow
        and "run: python3 -I scripts/linux/select-gpu-matrix.py" in workflow
        and "runs-on: [self-hosted, Linux, '${{ matrix.runner-arch }}', '${{ matrix.gpu-runner }}']"
        in workflow
        and workflow.count("fail-fast: false") == 4
        and "          test -f third_party/ANTfrastructure/shared/python/compare_detector_parity.py || { echo 'Pinned ANTfrastructure lacks detector parity comparison' >&2; exit 1; }"
        in preflight.splitlines()
        and "          bash scripts/linux/tests/test-check-gpu-detector-parity.sh"
        in preflight.splitlines()
        and "          python3 scripts/linux/tests/test-profile-parity-mutations.py"
        in preflight.splitlines()
        and "          python3 -I third_party/ANTfrastructure/shared/python/tests/test_compare_detector_parity.py"
        in preflight.splitlines()
        and "          python3 -I third_party/ANTfrastructure/shared/python/compare_detector_parity.py --help | grep -q -- --pairwise"
        in preflight.splitlines()
        and "          python3 -I third_party/ANTfrastructure/shared/python/verify_ort_profile.py --help | grep -q -- --min-runs"
        in preflight.splitlines()
        and "        if: ${{ inputs.promote-verified }}"
        in profile.group(1).splitlines()
        and f"actions/gpu-package-check@{HUB}" in profile.group(1)
        and "        if: ${{ inputs.promote-verified }}"
        in clean_profile.group(1).splitlines()
        and f"actions/clean-host-package-check@{HUB}" in clean_profile.group(1)
        and "    if: ${{ inputs.verify-gpu }}" in gpu.splitlines()
        and "    if: ${{ inputs.promote-verified && inputs.verify-gpu }}"
        in stage.splitlines()
        and all(
            line in clean_profile.group(1).splitlines()
            and line in profile.group(1).splitlines()
            and line in stage.splitlines()
            for line in (
                "          artifact-id: ${{ steps.metadata.outputs.artifact_id }}",
                "          artifact-digest: ${{ steps.metadata.outputs.artifact_digest }}",
                "          artifact-files: ${{ steps.metadata.outputs.files }}",
                "          gpu-vendor: ${{ matrix.vendor }}",
                "          gpu-arch: ${{ matrix.arch }}",
            )
        )
        and "          gpu-receipt: ${{ runner.temp }}/gpu-clean-receipt.json"
        in clean_profile.group(1).splitlines()
        and "          gpu-receipt: ${{ runner.temp }}/gpu-profile-receipt.json"
        in profile.group(1).splitlines()
        and "          clean-receipt: ${{ runner.temp }}/gpu-clean-receipt/gpu-clean-receipt.json"
        in stage.splitlines()
        and "          gpu-receipt: ${{ runner.temp }}/gpu-profile-receipt/gpu-profile-receipt.json"
        in stage.splitlines()
        and "          archive: ${{ steps.archive.outputs.path }}" in stage.splitlines()
        and "          output: ${{ runner.temp }}/gpu-verified-packages"
        in stage.splitlines()
        and "          path: ${{ runner.temp }}/gpu-verified-packages/*"
        in stage.splitlines()
        and "name: Upload the GPU profile receipt" in gpu
        and gpu.index("name: Profile the immutable packages")
        < gpu.index("name: Upload the GPU profile receipt")
        and "unverified-accelerantgine-gpu-clean-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}"
        in clean
        and "unverified-accelerantgine-gpu-clean-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}"
        in stage
        and "unverified-accelerantgine-gpu-profile-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}"
        in gpu
        and "unverified-accelerantgine-gpu-profile-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}"
        in stage
        and f"actions/stage-gpu-artifact@{HUB}" in stage
        and "name: Upload the checked packages" in stage
        and stage.index(f"actions/stage-gpu-artifact@{HUB}")
        < stage.index("name: Upload the checked packages")
        and '          command: env -u ORT_DYLIB_PATH -u ORT_LIB_LOCATION -u KATAGLYPHIS_ONNX_MODEL -u KATAGLYPHIS_ONNX_BACKEND -u KATAGLYPHIS_ORT_DEVICE bash scripts/linux/profile-gpu-candidate.sh "$GPU_PACKAGE_DIR" "$GITHUB_WORKSPACE/models/deim_dfine_n_coco.onnx" \'${{ matrix.device }}\''
        in profile.group(1).splitlines()
        and all(check in workflow for check in checks)
        and all(
            f"actions/{action}@{HUB}" in workflow
            for action in (
                "clean-host-package-check",
                "gpu-package-check",
                "stage-gpu-artifact",
            )
        )
        and "always()" not in workflow
        and "continue-on-error" not in workflow
    )


class MetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "output"
        self.metadata = self.root / "metadata.json"
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.files = [
            "accelerant_1_amd64.deb",
            "accelerant-1.tar.gz",
            "accelerant-1.AppImage",
        ]
        for name in self.files:
            (self.packages / name).write_bytes(b"package")
        self.env = {
            **os.environ,
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_REPOSITORY": "Kataglyphis/AccelerANTgine",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "41",
            "GITHUB_RUN_ATTEMPT": "2",
            "GPU_VENDOR": "nvidia",
            "GPU_ARCH": "arm64",
            "GPU_ARTIFACT_ID": "59",
            "GPU_ARTIFACT_DIGEST": "sha256:" + "b" * 64,
            "GPU_ARTIFACT_FILES": "\n".join(self.files),
        }

    def run_tool(self, mode, path, **updates):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), mode, str(path)],
            env={**self.env, **updates},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_select_create_resolve_and_reject_stale_or_cross_tuple(self):
        self.assertEqual(self.run_tool("select", self.packages).returncode, 0)
        self.assertEqual(self.run_tool("create", self.metadata).returncode, 0)
        self.assertNotEqual(self.run_tool("create", self.metadata).returncode, 0)
        result = self.run_tool("resolve", self.metadata)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("artifact_id=59\n", self.output.read_text())
        for update in (
            {"GITHUB_RUN_ATTEMPT": "3"},
            {"GITHUB_RUN_ID": "42"},
            {"GITHUB_SHA": "c" * 40},
            {"GPU_VENDOR": "amd", "GPU_ARCH": "x64"},
            {"GPU_VENDOR": "amd", "GPU_ARCH": "arm64"},
        ):
            with self.subTest(update=update):
                self.assertNotEqual(
                    self.run_tool("resolve", self.metadata, **update).returncode, 0
                )

    def test_metadata_rejects_malformed_inputs_and_duplicate_keys(self):
        self.assertEqual(self.run_tool("create", self.metadata).returncode, 0)
        original = json.loads(self.metadata.read_text())
        for key, value in (
            ("artifact_id", "0"),
            ("artifact_digest", "f" * 63),
            ("files", ["../evil.deb", "a.tar.gz", "a.AppImage"]),
            ("files", ["x.deb\nfiles<<BAD", "a.tar.gz", "a.AppImage"]),
            ("files", ["x.deb", "x.deb", "a.AppImage"]),
        ):
            with self.subTest(key=key, value=value):
                self.metadata.write_text(json.dumps({**original, key: value}))
                self.assertNotEqual(
                    self.run_tool("resolve", self.metadata).returncode, 0
                )
        self.metadata.write_text('{"run_id":"41","run_id":"41"}')
        self.assertNotEqual(self.run_tool("resolve", self.metadata).returncode, 0)

    def test_each_supported_tuple_has_its_own_identity(self):
        for vendor, arch in (("nvidia", "x64"), ("nvidia", "arm64"), ("amd", "x64")):
            path = self.root / f"{vendor}-{arch}.json"
            env = {"GPU_VENDOR": vendor, "GPU_ARCH": arch}
            with self.subTest(vendor=vendor, arch=arch):
                self.assertEqual(self.run_tool("create", path, **env).returncode, 0)
                self.assertEqual(self.run_tool("resolve", path, **env).returncode, 0)
                self.assertNotEqual(
                    self.run_tool(
                        "resolve", path, GITHUB_RUN_ATTEMPT="3", **env
                    ).returncode,
                    0,
                )

    def test_tuple_selection_defaults_and_preserves_failure_isolation(self):
        expected = {
            "nvidia-x64": (
                "nvidia",
                "x64",
                "latest-nvidia",
                "linux/amd64",
                "ubuntu-26.04",
                "X64",
                "gpu-nvidia-cuda",
                "cuda",
            ),
            "nvidia-arm64": (
                "nvidia",
                "arm64",
                "latest-nvidia",
                "linux/arm64",
                "ubuntu-26.04-arm",
                "ARM64",
                "gpu-nvidia-cuda",
                "cuda",
            ),
            "amd-x64": (
                "amd",
                "x64",
                "latest-rocm",
                "linux/amd64",
                "ubuntu-26.04",
                "X64",
                "gpu-amd-rocm",
                "migraphx",
            ),
        }
        keys = (
            "vendor",
            "arch",
            "tag",
            "platform",
            "runner",
            "runner-arch",
            "gpu-runner",
            "device",
        )
        outputs = {}
        for selector in ("all", *expected):
            output = self.root / f"matrix-{selector}"
            result = subprocess.run(
                [sys.executable, "-I", str(SELECT)],
                env={**self.env, "GPU_TUPLE": selector, "GITHUB_OUTPUT": str(output)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = output.read_text().removeprefix("matrix=")
            rows = json.loads(payload)["include"]
            values = [tuple(row[key] for key in keys) for row in rows]
            self.assertEqual(
                values,
                list(expected.values()) if selector == "all" else [expected[selector]],
            )
            outputs[selector] = rows
        for invalid in (
            "",
            "amd-arm64",
            "nvidia-riscv64",
            "windows-arm64",
            "all\nother",
            "unknown",
            "$(touch /tmp/not-a-tuple)",
        ):
            result = subprocess.run(
                [sys.executable, "-I", str(SELECT)],
                env={
                    **self.env,
                    "GPU_TUPLE": invalid,
                    "GITHUB_OUTPUT": str(self.root / "invalid"),
                },
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, invalid)
        self.assertFalse((self.root / "invalid").exists())
        self.assertEqual(len(outputs["nvidia-x64"]), 1)
        self.assertNotIn("amd", {row["vendor"] for row in outputs["nvidia-x64"]})
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("options: [all, nvidia-x64, nvidia-arm64, amd-x64]", workflow)
        self.assertEqual(workflow.count("        default: all"), 2)
        self.assertEqual(
            workflow.count(
                "matrix: ${{ fromJSON(needs.select-tuple.outputs.matrix) }}"
            ),
            4,
        )
        for needs in (
            "needs: [scope, select-tuple]",
            "needs: [scope, select-tuple, build]",
            "needs: [scope, select-tuple, build, clean-host]",
            "needs: [scope, select-tuple, build, clean-host, gpu-profile]",
        ):
            self.assertIn(needs, workflow)
        matrix_expression = "matrix: ${{ fromJSON(needs.select-tuple.outputs.matrix) }}"
        pieces = workflow.split(matrix_expression)
        self.assertEqual(len(pieces), 5)
        for index in range(4):
            mutant = (
                matrix_expression.join(pieces[: index + 1])
                + "matrix: {}"
                + matrix_expression.join(pieces[index + 1 :])
            )
            self.assertFalse(promotion_contract(mutant))

    def test_select_rejects_missing_and_duplicate_formats(self):
        (self.packages / self.files[0]).unlink()
        self.assertNotEqual(self.run_tool("select", self.packages).returncode, 0)
        (self.packages / self.files[0]).write_bytes(b"x")
        (self.packages / "extra.deb").write_bytes(b"x")
        self.assertNotEqual(self.run_tool("select", self.packages).returncode, 0)

    def test_workflow_binds_every_check_to_tuple_and_attempt(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertTrue(promotion_contract(workflow))
        meta = "unverified-accelerantgine-gpu-meta-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}${{ needs.scope.outputs.suffix }}"
        self.assertEqual(workflow.count(meta), 4)
        self.assertEqual(
            workflow.count(
                'gpu-promotion-metadata.py resolve "$RUNNER_TEMP/gpu-metadata/gpu-metadata.json"'
            ),
            3,
        )
        self.assertIn(
            "if: ${{ inputs.promote-verified && !inputs.verify-gpu }}", workflow
        )
        self.assertIn(
            "needs: [scope, select-tuple, build, clean-host, gpu-profile]", workflow
        )
        for action in (
            "clean-host-package-check",
            "gpu-package-check",
            "stage-gpu-artifact",
        ):
            self.assertIn(f"actions/{action}@{HUB}", workflow)
        self.assertEqual(workflow.count("digest-mismatch: error"), 6)
        self.assertIn("skip-decompress: true", workflow)
        self.assertIn(
            "artifact-ids: ${{ steps.metadata.outputs.artifact_id }}", workflow
        )
        self.assertIn("actions/clean-host-package-check@develop", workflow)
        for before, after in (
            (
                "promote-verified:\n        type: boolean\n        default: false",
                "promote-verified:\n        type: boolean\n        default: true",
            ),
            (
                "promote-verified:\n        description: Stage packages after clean-host and CPU/GPU detector parity checks\n        type: boolean\n        default: false",
                "promote-verified:\n        description: Stage packages after clean-host and CPU/GPU detector parity checks\n        type: boolean\n        default: true",
            ),
            (
                "name: Profile the immutable packages\n        if: ${{ inputs.promote-verified }}",
                "name: Profile the immutable packages\n        if: ${{ inputs.promote-verified }}\n        continue-on-error: true",
            ),
            ("name: Profile the immutable packages", "name: Skip immutable profile"),
            ("    if: ${{ inputs.verify-gpu }}", "    if: ${{ always() }}"),
            (
                "echo '::error::Promotion requires verify-gpu.'\n          exit 1",
                "echo '::error::Promotion requires verify-gpu.'\n          true",
            ),
            (
                "name: Check pinned GPU packaging APIs\n        shell: bash\n        run: |\n          set -euo pipefail",
                "name: Check pinned GPU packaging APIs\n        shell: bash\n        run: |\n          true",
            ),
            (
                "${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}",
                "wrong-tuple",
            ),
            ("inputs.promote-verified && inputs.verify-gpu", "always()"),
            (
                "needs: [scope, select-tuple, build, clean-host, gpu-profile]",
                "needs: [scope, select-tuple, build, clean-host]",
            ),
            ("needs: [scope, select-tuple]", "needs: missing-selector"),
            ("needs: [scope, select-tuple, build]", "needs: build"),
            (
                "needs: [scope, select-tuple, build, clean-host]",
                "needs: [build, clean-host]",
            ),
            (
                "matrix: ${{ fromJSON(needs.select-tuple.outputs.matrix) }}",
                "matrix: {}",
            ),
            ("GPU_TUPLE: ${{ inputs.gpu-tuple }}", "GPU_TUPLE: all"),
            ("${{ matrix.gpu-runner }}", "${{ matrix.runner }}"),
            (
                'bash scripts/linux/profile-gpu-candidate.sh "$GPU_PACKAGE_DIR"',
                'true # bash scripts/linux/profile-gpu-candidate.sh "$GPU_PACKAGE_DIR"',
            ),
            ("'${{ matrix.device }}'", "'${{ matrix.device }}' || true"),
            (
                "test -f third_party/ANTfrastructure/shared/python/compare_detector_parity.py",
                "true # missing comparator",
            ),
            (
                "          bash scripts/linux/tests/test-check-gpu-detector-parity.sh",
                "          bash scripts/linux/tests/test-check-gpu-detector-parity.sh || true",
            ),
            (
                "          python3 scripts/linux/tests/test-profile-parity-mutations.py",
                "          python3 scripts/linux/tests/test-profile-parity-mutations.py || true",
            ),
            (
                "          python3 -I third_party/ANTfrastructure/shared/python/tests/test_compare_detector_parity.py",
                "          python3 -I third_party/ANTfrastructure/shared/python/tests/test_compare_detector_parity.py || true",
            ),
            (
                "          python3 -I third_party/ANTfrastructure/shared/python/compare_detector_parity.py --help | grep -q -- --pairwise",
                "          true # skipped pairwise API check",
            ),
            (
                "          python3 -I third_party/ANTfrastructure/shared/python/verify_ort_profile.py --help | grep -q -- --min-runs",
                "          true # skipped profile interval API check",
            ),
            (
                "          test -f third_party/ANTfrastructure/shared/python/compare_detector_parity.py || { echo 'Pinned ANTfrastructure lacks detector parity comparison' >&2; exit 1; }",
                "          test -f third_party/ANTfrastructure/shared/python/compare_detector_parity.py || true",
            ),
            (
                "artifact-ids: ${{ steps.metadata.outputs.artifact_id }}",
                "artifact-ids: 1",
            ),
            (
                "clean-receipt: ${{ runner.temp }}/gpu-clean-receipt/gpu-clean-receipt.json",
                "clean-receipt: missing.json",
            ),
            (
                "gpu-receipt: ${{ runner.temp }}/gpu-profile-receipt/gpu-profile-receipt.json",
                "gpu-receipt: missing.json",
            ),
            (
                "archive: ${{ steps.archive.outputs.path }}",
                "archive: unchecked.zip",
            ),
            (
                "output: ${{ runner.temp }}/gpu-verified-packages",
                "output: unchecked-packages",
            ),
            (f"actions/stage-gpu-artifact@{HUB}", "actions/stage-gpu-artifact@develop"),
            (
                "gpu-promotion-metadata.py resolve ",
                "gpu-promotion-metadata.py ignored ",
            ),
        ):
            with self.subTest(before=before):
                self.assertIn(before, workflow)
                self.assertFalse(promotion_contract(workflow.replace(before, after)))
        for line in (
            "          artifact-id: ${{ steps.metadata.outputs.artifact_id }}",
            "          artifact-digest: ${{ steps.metadata.outputs.artifact_digest }}",
            "          artifact-files: ${{ steps.metadata.outputs.files }}",
            "          gpu-vendor: ${{ matrix.vendor }}",
            "          gpu-arch: ${{ matrix.arch }}",
        ):
            parts = workflow.split(line)
            self.assertEqual(len(parts), 4, line)
            for index in range(3):
                with self.subTest(line=line, occurrence=index):
                    mutant = (
                        line.join(parts[: index + 1])
                        + "          invalid: true"
                        + line.join(parts[index + 1 :])
                    )
                    self.assertFalse(promotion_contract(mutant))

    def test_clean_host_checks_successful_tuples_after_another_build_fails(self):
        clean = (
            WORKFLOW.read_text(encoding="utf-8")
            .split("\n  clean-host:\n", 1)[1]
            .split("\n  gpu-profile:\n", 1)[0]
        )
        self.assertIn(
            "    if: ${{ !cancelled() && needs.scope.result == 'success' && "
            "needs.select-tuple.result == 'success' && "
            "(needs.build.result == 'success' || needs.build.result == 'failure') }}",
            clean.splitlines(),
        )
        self.assertIn("needs: [scope, select-tuple, build]", clean)
        self.assertIn("actions/download-artifact@", clean)
        self.assertIn("actions/clean-host-package-check@", clean)
        self.assertIn(
            "artifact: accelerantgine-unverified-gpu-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}${{ needs.scope.outputs.suffix }}",
            clean,
        )
        self.assertIn(
            "name: unverified-accelerantgine-gpu-meta-${{ matrix.vendor }}-${{ matrix.arch }}-${{ github.run_id }}-attempt-${{ github.run_attempt }}${{ needs.scope.outputs.suffix }}",
            clean,
        )
        self.assertNotIn("continue-on-error", clean)

    def test_locked_model_api_preflight_is_before_image_pull(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        preflight = workflow.split("name: Check pinned GPU packaging APIs", 1)[1].split(
            "name: Select registry image", 1
        )[0]
        preflight = preflight.split(
            "test -f third_party/ANTfrastructure/shared/python/compare_detector_parity.py",
            1,
        )[0]
        for path in (
            "third_party/ANTfrastructure/shared/python/verify_locked_files.py",
            "third_party/ANTfrastructure/linux/scripts/lib/fetch-data-lock.py",
        ):
            self.assertIn(path, preflight)
        model_gate = (
            'if ! test -f "$model_verifier"'
            + preflight.split('if ! test -f "$model_verifier"', 1)[1].split(
                "\n          fi", 1
            )[0]
        )
        required = (
            'test -f "$model_verifier"',
            'test -f "$model_fetcher"',
            "grep -q '^def read_lock('",
            "grep -q '^def matches('",
            "exit 1",
        )
        self.assertTrue(all(token in model_gate for token in required))
        for token in required:
            with self.subTest(missing=token):
                mutant = model_gate.replace(token, "missing", 1)
                self.assertFalse(all(part in mutant for part in required))

    def test_gpu_profile_bootstrap_is_checked_before_image_pull(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        preflight = workflow.split("name: Check pinned GPU packaging APIs", 1)[1].split(
            "name: Select registry image", 1
        )[0]
        self.assertIn(
            "profile_log=third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh",
            preflight,
        )
        profile_gate = (
            'if ! test -f "$profile_env"'
            + preflight.split('if ! test -f "$profile_env"', 1)[1].split(
                "\n          fi", 1
            )[0]
        )
        for token in ('test -f "$profile_env"', 'test -f "$profile_log"', "exit 1"):
            with self.subTest(missing=token):
                self.assertIn(token, profile_gate)

    @unittest.skipIf(os.name == "nt", "the clean-host command uses Linux Bash")
    def test_clean_host_commands_clear_poisoned_runtime_overrides(self):
        text = (
            WORKFLOW.read_text(encoding="utf-8")
            .split("name: Check immutable packages on the clean host", 1)[1]
            .split("name: Upload the clean-host receipt", 1)[0]
        )
        commands = re.findall(
            r"(?m)^          (?:deb|tarball|appimage)-command: (.+)$", text
        )
        self.assertEqual(len(commands), 3)
        binary = self.root / "usr/bin"
        binary.mkdir(parents=True)
        workspace_script = self.root / "scripts/linux/check-clean-host-inference.sh"
        workspace_script.parent.mkdir(parents=True)
        stub = "#!/usr/bin/env bash\nset -eu\nfor name in LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT ORT_DYLIB_PATH ORT_LIB_LOCATION KATAGLYPHIS_ONNX_MODEL KATAGLYPHIS_ONNX_BACKEND; do [[ ! -v $name ]] || exit 1; done\n"
        for path in (
            binary / "AccelerANTgine",
            workspace_script,
            self.root / "candidate.AppImage",
        ):
            path.write_text(stub)
            path.chmod(0o755)
        env = {
            **self.env,
            "GITHUB_WORKSPACE": str(self.root),
            "APPIMAGE": str(self.root / "candidate.AppImage"),
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        }
        for name in (
            "LD_LIBRARY_PATH",
            "LD_PRELOAD",
            "LD_AUDIT",
            "ORT_DYLIB_PATH",
            "ORT_LIB_LOCATION",
            "KATAGLYPHIS_ONNX_MODEL",
            "KATAGLYPHIS_ONNX_BACKEND",
        ):
            env[name] = "/bad/override"
        for command in commands:
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=self.root,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        poisoned = commands[0].replace("-u ORT_LIB_LOCATION ", "")
        self.assertNotEqual(
            subprocess.run(
                ["bash", "-c", poisoned],
                cwd=self.root,
                env=env,
                capture_output=True,
                check=False,
            ).returncode,
            0,
        )


if __name__ == "__main__":
    unittest.main()
