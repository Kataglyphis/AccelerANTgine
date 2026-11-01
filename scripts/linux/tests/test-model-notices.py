#!/usr/bin/env python3
"""Verify that bundled model assets carry their license and notice."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "third_party_notices", ROOT / "scripts/packaging/third_party_notices.py"
)
assert SPEC and SPEC.loader
NOTICES = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = NOTICES
SPEC.loader.exec_module(NOTICES)


class ModelNotices(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.model_dir = self.root / "bin/models"
        self.model_dir.mkdir(parents=True)
        self.stager = NOTICES.Stager.__new__(NOTICES.Stager)
        self.stager.root = self.root
        self.stager.dest = self.root / "licenses"
        self.stager.platform = "windows"
        self.stager.roots = {"install": self.root}
        self.stager.variables = {}
        self.stager.components = {}
        manifest = json.loads(
            (ROOT / "packaging/third-party/components.json").read_text(encoding="utf-8")
        )
        self.stager.inventory = {
            "components": [
                entry
                for entry in manifest["components"]
                if entry["id"] == "deim-dfine-n-coco"
            ]
        }

    def test_absent_model_is_not_listed(self) -> None:
        self.stager.add_assets()
        self.assertEqual(self.stager.components, {})

    def test_shipped_model_requires_and_lists_both_texts(self) -> None:
        for name in (
            "deim_dfine_n_coco.onnx",
            "deim_dfine_n_coco.LICENSE",
            "deim_dfine_n_coco.NOTICE",
        ):
            (self.model_dir / name).write_text("fixture", encoding="utf-8")
        self.stager.add_assets()
        component = self.stager.components["deim-dfine-n-coco"]
        self.assertEqual(component.files, ["bin/models/deim_dfine_n_coco.onnx"])
        self.assertEqual(
            component.texts,
            [
                "licenses/third-party/deim-dfine-n-coco/deim_dfine_n_coco.LICENSE",
                "licenses/third-party/deim-dfine-n-coco/deim_dfine_n_coco.NOTICE",
            ],
        )
        (self.model_dir / "deim_dfine_n_coco.NOTICE").unlink()
        with self.assertRaisesRegex(NOTICES.NoticeError, "deim_dfine_n_coco.NOTICE"):
            self.stager.add_assets()

    def test_finished_notice_staging_includes_the_model(self) -> None:
        (self.root / "app.exe").write_bytes(b"MZ")
        (self.root / "LICENSE").write_text("license", encoding="utf-8")
        for name in (
            "deim_dfine_n_coco.onnx",
            "deim_dfine_n_coco.LICENSE",
            "deim_dfine_n_coco.NOTICE",
        ):
            (self.model_dir / name).write_text("fixture", encoding="utf-8")
        manifest = self.root / "manifest.json"
        manifest.write_text(
            json.dumps(
                {"version": 1, "project_binaries": ["app.exe"], **self.stager.inventory}
            ),
            encoding="utf-8",
        )
        command = [
            sys.executable,
            str(ROOT / "scripts/packaging/third_party_notices.py"),
            "--manifest",
            str(manifest),
            "--root",
            str(self.root),
            "--dest",
            str(self.stager.dest),
            "--platform",
            "windows",
            "--repo",
            str(ROOT),
            "--project-license",
            "LICENSE",
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(
            (self.stager.dest / "third-party-inventory.json").read_text(
                encoding="utf-8"
            )
        )
        model = next(
            item for item in output["components"] if item["id"] == "deim-dfine-n-coco"
        )
        self.assertIn(
            "licenses/third-party/deim-dfine-n-coco/deim_dfine_n_coco.NOTICE",
            model["texts"],
        )
        (self.model_dir / "deim_dfine_n_coco.NOTICE").unlink()
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deim_dfine_n_coco.NOTICE", result.stderr)


if __name__ == "__main__":
    unittest.main()
