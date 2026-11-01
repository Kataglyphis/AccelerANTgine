#!/usr/bin/env python3
"""Exercise lock-checked demo model installation without a build or network."""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
NAMES = (
    "deim_dfine_n_coco.onnx",
    "deim_dfine_n_coco.LICENSE",
    "deim_dfine_n_coco.NOTICE",
)


class ModelInstall(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.models = self.root / "source" / "models"
        self.models.mkdir(parents=True)
        entries = []
        for name in NAMES:
            data = f"fixture {name}\n".encode()
            (self.models / name).write_bytes(data)
            entries.append(
                f"{hashlib.sha256(data).hexdigest()}  {name}  https://example.invalid/{name}\n"
            )
        (self.models / "models.lock").write_text("".join(entries), encoding="utf-8")

    def install(
        self, destination: str, *, destdir: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        template = (ROOT / "cmake/InstallDemoModel.cmake.in").read_text(
            encoding="utf-8"
        )
        template = template.replace(
            "@PROJECT_SOURCE_DIR@", (self.root / "source").as_posix()
        )
        template = template.replace("@DEMO_MODEL_INSTALL_DIR@", destination)
        script = self.root / "install.cmake"
        script.write_text(template, encoding="utf-8")
        env = os.environ.copy()
        env.pop("DESTDIR", None)
        if destdir is not None:
            env["DESTDIR"] = str(destdir)
        prefix = "/usr" if destdir else (self.root / "prefix").as_posix()
        return subprocess.run(
            ["cmake", f"-DCMAKE_INSTALL_PREFIX={prefix}", "-P", str(script)],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )

    def test_linux_and_windows_layouts(self) -> None:
        for destination in ("share/accelerantgine/models", "bin/models"):
            with self.subTest(destination=destination):
                result = self.install(destination)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in NAMES:
                    self.assertEqual(
                        (self.root / "prefix" / destination / name).read_bytes(),
                        (self.models / name).read_bytes(),
                    )

    @unittest.skipIf(os.name == "nt", "DESTDIR staging uses POSIX installation paths")
    def test_destdir_is_applied_once(self) -> None:
        staging = self.root / "stage"
        result = self.install("share/accelerantgine/models", destdir=staging)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in NAMES:
            self.assertEqual(
                (staging / "usr/share/accelerantgine/models" / name).read_bytes(),
                (self.models / name).read_bytes(),
            )

    def test_missing_file_fails_before_install(self) -> None:
        (self.models / NAMES[1]).unlink()
        result = self.install("share/accelerantgine/models")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing locked demo model file", result.stderr)
        self.assertFalse((self.root / "prefix").exists())

    def test_tampered_file_fails_before_install(self) -> None:
        (self.models / NAMES[2]).write_text("changed", encoding="utf-8")
        result = self.install("bin/models")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match models.lock", result.stderr)
        self.assertFalse((self.root / "prefix").exists())

    def test_duplicate_lock_entry_fails(self) -> None:
        lock = self.models / "models.lock"
        lock.write_text(
            lock.read_text(encoding="utf-8") + lock.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        result = self.install("bin/models")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate demo model lock entry", result.stderr)


if __name__ == "__main__":
    unittest.main()
