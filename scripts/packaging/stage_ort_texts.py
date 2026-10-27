#!/usr/bin/env python3
# Copyright (c) 2026 Jonas Heinle
# SPDX-License-Identifier: MIT
"""Stage ONNX Runtime's LICENSE and ThirdPartyNotices.txt for the chain library a Linux package bundles."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

TEXTS = ("LICENSE", "ThirdPartyNotices.txt")
VERSIONED = re.compile(r"^libonnxruntime\.so\.(\d+\.\d+\.\d+)$")
MAX_TEXT_BYTES = 16 * 1024 * 1024


class StageError(Exception):
    """No text source can be tied to the bundled library."""


def sha256(path: Path) -> str:
    """Hash a file in chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def chain_version(chain_dir: Path) -> str:
    """The chain build installs exactly one fully versioned library."""
    versions = {
        m.group(1) for p in chain_dir.iterdir() if (m := VERSIONED.match(p.name))
    }
    if len(versions) != 1:
        raise StageError(
            f"expected one versioned libonnxruntime in {chain_dir}, found {sorted(versions)}"
        )
    return versions.pop()


def checked_text(data: bytes, origin: str) -> bytes:
    """Refuse empty, binary or oversized notice text."""
    if not data.strip() or b"\0" in data or len(data) > MAX_TEXT_BYTES:
        raise StageError(f"license text is empty, binary or too large: {origin}")
    data.decode("utf-8")
    return data


def from_chain(chain_dir: Path) -> dict[str, bytes] | None:
    """Prefer the texts the chain build copied from the checkout it compiled."""
    licenses = chain_dir.parent / "licenses"
    if not all((licenses / name).is_file() for name in TEXTS):
        return None
    return {
        name: checked_text((licenses / name).read_bytes(), str(licenses / name))
        for name in TEXTS
    }


def from_byte_match(args: argparse.Namespace, library: Path) -> bool:
    """ANTfrastructure's stager, when one wheel ships this library byte for byte."""
    result = subprocess.run(
        [
            sys.executable,
            str(args.wheel_stager),
            "--wheel-dir",
            str(args.wheel_dir),
            "--destination",
            str(args.destination.parent.parent),
            "--strip",
            args.strip,
            "--library",
            str(library),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def from_version_match(
    wheel_dir: Path, version: str
) -> tuple[dict[str, bytes], list[str]]:
    """Every chain wheel of the library's version must carry the same two texts."""
    texts: dict[str, bytes] | None = None
    wheels: list[str] = []
    for wheel in sorted(wheel_dir.glob(f"onnxruntime*-{version}-*.whl")):
        if wheel.name.startswith("onnxruntime_genai-"):
            continue
        with zipfile.ZipFile(wheel) as archive:
            names = set(archive.namelist())
            if any(f"onnxruntime/{name}" not in names for name in TEXTS):
                raise StageError(f"{wheel.name} lacks ONNX Runtime's license texts")
            found = {
                name: checked_text(archive.read(f"onnxruntime/{name}"), wheel.name)
                for name in TEXTS
            }
        if texts is not None and found != texts:
            raise StageError(
                f"chain wheels of {version} disagree on their license texts"
            )
        texts = found
        wheels.append(wheel.name)
    if texts is None:
        raise StageError(f"no chain wheel of ONNX Runtime {version} in {wheel_dir}")
    return texts, wheels


def write(destination: Path, texts: dict[str, bytes]) -> None:
    """Write both texts, keeping identical ones from an earlier install."""
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in texts.items():
        (destination / name).write_bytes(data)


def main(argv: list[str]) -> int:
    """Entry point."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--library", type=Path, required=True, help="the bundled libonnxruntime"
    )
    parser.add_argument(
        "--chain-dir", type=Path, required=True, help="the chain build's lib directory"
    )
    parser.add_argument("--wheel-dir", type=Path, required=True)
    parser.add_argument(
        "--wheel-stager",
        type=Path,
        required=True,
        help="ANTfrastructure stage-ort-wheel-licenses.py",
    )
    parser.add_argument("--strip", default="strip")
    parser.add_argument(
        "--destination",
        type=Path,
        required=True,
        help="directory receiving the two texts",
    )
    args = parser.parse_args(argv)
    try:
        version = chain_version(args.chain_dir)
        chain_library = args.chain_dir / f"libonnxruntime.so.{version}"
        if sha256(args.library) != sha256(chain_library):
            raise StageError(f"{args.library} is not the chain build {chain_library}")
        texts = from_chain(args.chain_dir)
        if texts is not None:
            write(args.destination, texts)
            print(
                f"PASS: ONNX Runtime {version} texts from the chain build's licenses/"
            )
            return 0
        byte_match_layout = (
            args.destination.name == "onnxruntime"
            and args.destination.parent.name == "licenses"
        )
        if byte_match_layout and from_byte_match(args, args.library):
            print(f"PASS: ONNX Runtime {version} texts from the byte-identical wheel")
            return 0
        texts, wheels = from_version_match(args.wheel_dir, version)
        write(args.destination, texts)
        print(
            f"WARN: ONNX Runtime {version} texts from the chain wheel of the same version ({', '.join(wheels)}); "
            "this image's chain library carries no licenses/ of its own"
        )
    except (StageError, OSError, UnicodeError, zipfile.BadZipFile) as error:
        print(f"FAIL: ONNX Runtime texts: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
