#!/usr/bin/env python3
"""Fails when a built wheel's kataglyphis_inference/_core.pyi differs from the tracked stub that ty reads.
It does not see Windows-built stubs, a build without ONNX Runtime or whether stubgen describes the module correctly."""

from __future__ import annotations

import argparse
import difflib
import sys
import zipfile
from pathlib import Path

MEMBER = "kataglyphis_inference/_core.pyi"
TRACKED = Path(__file__).resolve().parents[2] / "Bindings/python/kataglyphis_inference/_core.pyi"


def built_stub(wheel: Path) -> bytes:
    """The stub the wheel ships; a missing member is a build error, not drift."""
    with zipfile.ZipFile(wheel) as archive:
        try:
            return archive.read(MEMBER)
        except KeyError:
            raise SystemExit(f"check-python-stub: {wheel} carries no {MEMBER}") from None


def main(argv: list[str] | None = None) -> int:
    """Compare the wheel's stub with the tracked one byte for byte."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheel", type=Path)
    parser.add_argument("--tracked", type=Path, default=TRACKED)
    args = parser.parse_args(argv)
    built = built_stub(args.wheel)
    tracked = args.tracked.read_bytes()
    if built == tracked:
        print(f"check-python-stub: {args.tracked.name} matches {args.wheel.name}")
        return 0
    diff = difflib.unified_diff(
        tracked.decode("utf-8", "replace").splitlines(keepends=True),
        built.decode("utf-8", "replace").splitlines(keepends=True),
        fromfile=f"tracked/{MEMBER}",
        tofile=f"built/{MEMBER}",
    )
    sys.stdout.writelines(diff)
    print(f"check-python-stub: the tracked stub is stale; copy {MEMBER} from the wheel to {args.tracked}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
