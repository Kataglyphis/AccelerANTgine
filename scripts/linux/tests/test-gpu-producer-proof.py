#!/usr/bin/env python3
"""Exercise the verification-to-upload producer proof without a GPU build."""

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/linux/gpu-producer-proof.py"
WORKFLOW = ROOT / ".github/workflows/linux-gpu-candidate.yml"
BUILD = ROOT / "scripts/linux/ci-gpu-candidate.sh"


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "packages"
        self.directory.mkdir()
        self.names = [
            "engine-gpu-nvidia.deb",
            "engine-gpu-nvidia.tar.gz",
            "engine-gpu-nvidia.AppImage",
        ]
        for name in self.names:
            (self.directory / name).write_bytes(name.encode())
        self.before = self.root / "before.json"
        self.proof = self.root / "proof.json"
        self.output = self.root / "github-output"
        self.env = {
            **os.environ,
            "GITHUB_REPOSITORY": "Kataglyphis/AccelerANTgine",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "17",
            "GITHUB_RUN_ATTEMPT": "2",
            "GPU_VARIANT": "nvidia",
            "GPU_ARCH": "x64",
            "GITHUB_OUTPUT": str(self.output),
        }

    def run_proof(self, mode, *args, env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), mode, *map(str, args)],
            env=env or self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def capture(self):
        result = self.run_proof(
            "capture", "--directory", self.directory, "--proof", self.before
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def seal(self):
        result = self.run_proof(
            "seal",
            "--directory",
            self.directory,
            "--before",
            self.before,
            "--proof",
            self.proof,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def archive(self):
        archive = self.root / "artifact.zip"
        with zipfile.ZipFile(archive, "w") as output:
            for name in self.names:
                output.write(self.directory / name, name)
        return archive

    def verify_archive(self, archive, digest=None, proof_digest=None):
        return self.run_proof(
            "archive",
            "--proof",
            self.proof,
            "--proof-sha",
            proof_digest or hashlib.sha256(self.proof.read_bytes()).hexdigest(),
            "--archive",
            archive,
            "--archive-sha",
            digest or hashlib.sha256(archive.read_bytes()).hexdigest(),
        )

    def test_verified_selection_and_exact_uploaded_archive(self):
        self.capture()
        self.seal()
        selected = self.run_proof(
            "select", "--directory", self.directory, "--proof", self.proof
        )
        self.assertEqual(selected.returncode, 0, selected.stderr)
        output = self.output.read_text(encoding="utf-8")
        self.assertIn("proof_sha256=", output)
        for name in self.names:
            self.assertIn(name, output)
        result = self.verify_archive(self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_swaps_before_and_after_verification_fail(self):
        self.capture()
        package = self.directory / self.names[0]
        package.write_bytes(b"different bytes")
        result = self.run_proof(
            "seal",
            "--directory",
            self.directory,
            "--before",
            self.before,
            "--proof",
            self.proof,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.proof.exists())
        package.write_bytes(self.names[0].encode())
        self.seal()
        package.write_bytes(b"swapped after proof")
        self.assertNotEqual(
            self.run_proof(
                "select", "--directory", self.directory, "--proof", self.proof
            ).returncode,
            0,
        )
        self.assertNotEqual(self.verify_archive(self.archive()).returncode, 0)

    def test_identity_and_proof_changes_fail(self):
        self.capture()
        wrong = {**self.env, "GITHUB_RUN_ATTEMPT": "3"}
        self.assertNotEqual(
            self.run_proof(
                "seal",
                "--directory",
                self.directory,
                "--before",
                self.before,
                "--proof",
                self.proof,
                env=wrong,
            ).returncode,
            0,
        )
        self.seal()
        archive = self.archive()
        self.assertNotEqual(self.verify_archive(archive, digest="0" * 64).returncode, 0)
        self.assertNotEqual(
            self.verify_archive(archive, proof_digest="0" * 64).returncode, 0
        )
        data = json.loads(self.proof.read_text(encoding="utf-8"))
        data["identity"]["vendor"] = "amd"
        self.proof.write_text(json.dumps(data), encoding="utf-8")
        self.assertNotEqual(self.verify_archive(archive).returncode, 0)

    def test_extra_missing_and_unsafe_archive_files_fail(self):
        self.capture()
        self.seal()
        archive = self.archive()
        with zipfile.ZipFile(archive, "a") as output:
            output.writestr("../escape", b"bad")
        self.assertNotEqual(self.verify_archive(archive).returncode, 0)
        (self.directory / self.names[1]).unlink()
        self.assertNotEqual(
            self.run_proof(
                "select", "--directory", self.directory, "--proof", self.proof
            ).returncode,
            0,
        )

    def test_unsupported_gpu_tuple_fails(self):
        env = {**self.env, "GPU_VARIANT": "amd", "GPU_ARCH": "arm64"}
        self.assertNotEqual(
            self.run_proof(
                "capture",
                "--directory",
                self.directory,
                "--proof",
                self.before,
                env=env,
            ).returncode,
            0,
        )

    def test_duplicate_proof_keys_fail(self):
        self.capture()
        original = self.before.read_text(encoding="utf-8")
        self.before.write_text(
            original.replace('"schema":1', '"schema":1,"schema":1'), encoding="utf-8"
        )
        result = self.run_proof(
            "seal",
            "--directory",
            self.directory,
            "--before",
            self.before,
            "--proof",
            self.proof,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.proof.exists())

    @unittest.skipIf(os.name == "nt", "symlink fixtures need Linux permissions")
    def test_symlinked_source_is_not_proof_material(self):
        package = self.directory / self.names[0]
        original = self.root / "original"
        package.rename(original)
        package.symlink_to(original)
        result = self.run_proof(
            "capture", "--directory", self.directory, "--proof", self.before
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.before.exists())


def safe_wiring(build: str, workflow: str) -> bool:
    positions = [
        build.find(token)
        for token in (
            "gpu-producer-proof.py capture",
            "bash scripts/linux/verify-gpu-packages.sh",
            "gpu-producer-proof.py seal",
        )
    ]
    required = (
        "-e GPU_PRODUCER_PROOF=1",
        "-e GPU_VARIANT=${{ matrix.vendor }}",
        "-e GPU_ARCH=${{ matrix.arch }}",
        "-e GITHUB_REPOSITORY",
        "-e GITHUB_SHA",
        "-e GITHUB_RUN_ID",
        "-e GITHUB_RUN_ATTEMPT",
        "python3 scripts/linux/tests/test-gpu-producer-proof.py",
        "gpu-producer-proof.py select",
        "path: ${{ steps.proof.outputs.paths }}",
        "artifact-ids: ${{ inputs.promote-verified && steps.promotion_upload.outputs.artifact-id || steps.candidate_upload.outputs.artifact-id }}",
        "skip-decompress: true",
        "digest-mismatch: error",
        "      - name: Require the upload to contain the producer-verified bytes\n        env:",
        "gpu-producer-proof.py archive",
        '--proof-sha "$PRODUCER_PROOF_SHA"',
        "needs: [scope, select-tuple, build, clean-host, gpu-profile]",
        "  stage-verified:\n    if: ${{ inputs.promote-verified && inputs.verify-gpu }}",
        "GPU_PRODUCER_PROOF_SHA256: ${{ steps.proof.outputs.proof_sha256 }}",
        "name: Download this attempt's producer proof",
        "      - name: Recheck the producer proof and immutable archive\n        env:",
        "PRODUCER_PROOF_SHA: ${{ steps.metadata.outputs.producer_proof_sha256 }}",
        '--proof "$RUNNER_TEMP/gpu-producer-proof/producer-proof.json"',
    )
    return (
        min(positions) >= 0
        and positions == sorted(positions)
        and all(item in workflow for item in required)
        and workflow.index("gpu-producer-proof.py archive")
        < workflow.index("gpu-promotion-metadata.py create")
        and workflow.index("name: Recheck the producer proof and immutable archive")
        < workflow.index("actions/stage-gpu-artifact@")
        and "continue-on-error:" not in workflow
    )


class WiringTests(unittest.TestCase):
    def test_proof_is_required_before_and_after_upload(self):
        build, workflow = (
            BUILD.read_text(encoding="utf-8"),
            WORKFLOW.read_text(encoding="utf-8"),
        )
        self.assertTrue(safe_wiring(build, workflow))
        for before, after in (
            ("gpu-producer-proof.py capture", "true"),
            ("gpu-producer-proof.py seal", "true"),
            ("gpu-producer-proof.py select", "true"),
            ("gpu-producer-proof.py archive", "true"),
            ("-e GPU_PRODUCER_PROOF=1", "-e GPU_PRODUCER_PROOF=0"),
            ("path: ${{ steps.proof.outputs.paths }}", "path: build-gpu/*.deb"),
            (
                "  stage-verified:\n    if: ${{ inputs.promote-verified && inputs.verify-gpu }}",
                "  stage-verified:\n    if: ${{ always() }}",
            ),
            (
                "name: Download this attempt's producer proof",
                "name: Skip producer proof",
            ),
        ):
            with self.subTest(before=before):
                self.assertFalse(
                    safe_wiring(
                        build.replace(before, after), workflow.replace(before, after)
                    )
                )


@unittest.skipIf(os.name == "nt", "the CI script executes in Linux containers")
class ShellIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.workspace, binary = root / "workspace", root / "bin"
        (self.workspace / "scripts/linux").mkdir(parents=True)
        binary.mkdir()
        shutil.copy2(SCRIPT, self.workspace / "scripts/linux/gpu-producer-proof.py")
        self.stub(binary / "uname", "#!/bin/bash\necho x86_64\n")
        self.stub(
            binary / "python3",
            '#!/bin/bash\nif [ "$1" = "-I" ]; then exec '
            + shlex.quote(sys.executable)
            + ' "$@"; fi\nexit 0\n',
        )
        self.stub(
            binary / "bash",
            """#!/bin/bash
case "$1" in
  scripts/linux/ci-release.sh)
    mkdir -p build-gpu
    for ext in deb tar.gz AppImage; do printf '%s' "$ext" > "build-gpu/example.$ext"; done ;;
  scripts/linux/verify-gpu-packages.sh) test "${TEST_VERIFY_FAIL:-0}" = 0 ;;
  *) exit 1 ;;
esac
""",
        )
        self.env = {
            **os.environ,
            "PATH": f"{binary}{os.pathsep}{os.environ['PATH']}",
            "GPU_VARIANT": "nvidia",
            "GPU_ARCH": "x64",
            "GPU_PRODUCER_PROOF": "1",
            "GITHUB_REPOSITORY": "Kataglyphis/AccelerANTgine",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "17",
            "GITHUB_RUN_ATTEMPT": "2",
        }

    @staticmethod
    def stub(path, content):
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def run_build(self, env=None):
        return subprocess.run(
            ["/usr/bin/bash", str(BUILD)],
            cwd=self.workspace,
            env=env or self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_workflow_identity_produces_proof_and_stale_rerun_fails(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = self.workspace / "build-gpu/producer-proof.json"
        data = json.loads(proof.read_text(encoding="utf-8"))
        self.assertEqual(data["phase"], "passed")
        self.assertEqual(data["identity"]["run_attempt"], "2")
        self.assertEqual(data["identity"]["revision"], "a" * 40)
        before = proof.read_bytes()
        rerun = self.run_build()
        self.assertNotEqual(rerun.returncode, 0)
        self.assertIn("File exists", rerun.stderr)
        self.assertEqual(proof.read_bytes(), before)

    def test_failed_verifier_and_missing_identity_never_seal(self):
        result = self.run_build({**self.env, "TEST_VERIFY_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.workspace / "build-gpu/.producer-before.json").is_file())
        self.assertFalse((self.workspace / "build-gpu/producer-proof.json").exists())
        shutil.rmtree(self.workspace / "build-gpu")
        env = self.env.copy()
        env.pop("GITHUB_RUN_ATTEMPT")
        self.assertNotEqual(self.run_build(env).returncode, 0)
        self.assertFalse((self.workspace / "build-gpu/producer-proof.json").exists())

    def test_container_architecture_must_match_the_proof_tuple(self):
        result = self.run_build({**self.env, "GPU_ARCH": "arm64"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("architecture does not match", result.stderr)
        self.assertFalse((self.workspace / "build-gpu/producer-proof.json").exists())


if __name__ == "__main__":
    unittest.main()
