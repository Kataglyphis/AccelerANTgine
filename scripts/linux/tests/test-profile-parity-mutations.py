#!/usr/bin/env python3
"""Prove the per-package profile fixture catches a skipped or ignored parity check."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROFILE = ROOT / "scripts/linux/profile-gpu-candidate.sh"
FIXTURE = ROOT / "scripts/linux/tests/test-profile-gpu-candidate.sh"
EVIDENCE_LIB = ROOT / "scripts/linux/lib/detector-evidence.sh"
SUITE_FIXTURE = ROOT / "scripts/linux/tests/suite-fixture.sh"
CALL = '    bash "$repo/scripts/linux/check-gpu-detector-parity.sh" "$demo" "$resolved" "$device" "$stage/$kind-detector-parity"'


def main():
    original = PROFILE.read_text(encoding="utf-8")
    if original.count(CALL) != 1:
        raise SystemExit("Expected exactly one mandatory per-package parity call")
    variants = {
        "original": original,
        "missing": original.replace(CALL, "    :"),
        "ignored": original.replace(CALL, CALL + " || true"),
    }
    with tempfile.TemporaryDirectory(prefix="accelerant-profile-mutations.") as temp:
        root = Path(temp)
        profile = root / "scripts/linux/profile-gpu-candidate.sh"
        fixture = root / "scripts/linux/tests/test-profile-gpu-candidate.sh"
        fixture.parent.mkdir(parents=True)
        fixture.write_bytes(FIXTURE.read_bytes())
        (fixture.parent / SUITE_FIXTURE.name).write_bytes(SUITE_FIXTURE.read_bytes())
        evidence_lib = root / "scripts/linux/lib/detector-evidence.sh"
        evidence_lib.parent.mkdir(parents=True)
        evidence_lib.write_bytes(EVIDENCE_LIB.read_bytes())
        for name, content in variants.items():
            profile.write_text(content, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(fixture), str(ROOT / "third_party/ANTfrastructure")],
                capture_output=True,
                text=True,
                check=False,
            )
            if (result.returncode == 0) != (name == "original"):
                raise SystemExit(
                    f"Unexpected {name} mutation result: {result.returncode}\n"
                    f"{result.stdout}\n{result.stderr}"
                )
    print("Profile fixture rejects removed and swallowed parity checks")


if __name__ == "__main__":
    main()
