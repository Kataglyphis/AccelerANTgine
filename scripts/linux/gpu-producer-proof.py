#!/usr/bin/env python3
"""Bind verified GPU package bytes to the producer's immutable upload."""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import zipfile
from pathlib import Path

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~-]*\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
MAX_TOTAL = 40 * 1024**3


def identity() -> dict[str, str]:
    data = {
        key: os.environ[env]
        for key, env in {
            "repository": "GITHUB_REPOSITORY",
            "revision": "GITHUB_SHA",
            "run_id": "GITHUB_RUN_ID",
            "run_attempt": "GITHUB_RUN_ATTEMPT",
            "vendor": "GPU_VARIANT",
            "arch": "GPU_ARCH",
        }.items()
    }
    if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", data["repository"]):
        raise ValueError("invalid repository")
    if not re.fullmatch(r"[0-9a-f]{40}", data["revision"]):
        raise ValueError("invalid revision")
    if any(
        not re.fullmatch(r"[1-9][0-9]*", data[key]) for key in ("run_id", "run_attempt")
    ):
        raise ValueError("invalid run identity")
    if (data["vendor"], data["arch"]) not in {
        ("nvidia", "x64"),
        ("nvidia", "arm64"),
        ("amd", "x64"),
    }:
        raise ValueError("unsupported GPU tuple")
    return data


def digest_file(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"package must be a regular file: {path}")
    before = path.stat()
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
    if (
        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        or path.is_symlink()
        or path.stat().st_ino != after.st_ino
    ):
        raise ValueError("package changed while hashing")
    return {"size": after.st_size, "sha256": digest.hexdigest()}


def snapshot(directory: Path) -> dict[str, dict[str, object]]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("package directory must be a real directory")
    selected = []
    for suffix in (".deb", ".tar.gz", ".AppImage"):
        matches = list(directory.glob(f"*{suffix}"))
        if len(matches) != 1 or not NAME.fullmatch(matches[0].name):
            raise ValueError("expected one safely named package per format")
        selected.append(matches[0])
    if len({p.name.casefold() for p in selected}) != 3:
        raise ValueError("duplicate package names")
    result = {path.name: digest_file(path) for path in selected}
    if sum(item["size"] for item in result.values()) > MAX_TOTAL:
        raise ValueError("packages exceed size limit")
    return result


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("duplicate proof key")
        result[key] = value
    return result


def load(path: Path, phase: str) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError("missing or unsafe producer proof")
    data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=pairs)
    if not isinstance(data, dict) or set(data) != {
        "schema",
        "phase",
        "identity",
        "files",
    }:
        raise ValueError("invalid producer proof schema")
    if data["schema"] != 1 or data["phase"] != phase or data["identity"] != identity():
        raise ValueError("producer proof identity or phase does not match")
    return data


def write(path: Path, data: dict) -> None:
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(data, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")


def compare(directory: Path, data: dict) -> None:
    if snapshot(directory) != data["files"]:
        raise ValueError("package bytes or names differ from the producer proof")


def select(directory: Path, proof: Path) -> None:
    data = load(proof, "passed")
    compare(directory, data)
    names = sorted(data["files"])
    proof_hash = digest_file(proof)["sha256"]
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
        stream.write("paths<<GPU_PROOF_PATHS\n")
        stream.writelines(f"{directory.as_posix()}/{name}\n" for name in names)
        stream.write(f"GPU_PROOF_PATHS\nproof_sha256={proof_hash}\n")


def verify_entry(data: zipfile.ZipFile, item: zipfile.ZipInfo, expected: dict) -> None:
    mode = item.external_attr >> 16
    if item.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG):
        raise ValueError("archive contains a non-regular entry")
    if item.file_size > 1000 * max(item.compress_size, 1):
        raise ValueError("archive compression ratio is too high")
    digest = hashlib.sha256()
    with data.open(item) as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    if expected[item.filename] != {
        "size": item.file_size,
        "sha256": digest.hexdigest(),
    }:
        raise ValueError("uploaded package differs from the verified bytes")


def verify_archive(
    archive: Path, proof: Path, proof_sha: str, archive_sha: str
) -> None:
    if not SHA.fullmatch(proof_sha) or digest_file(proof)["sha256"] != proof_sha:
        raise ValueError("producer proof changed after selection")
    expected = load(proof, "passed")["files"]
    archive_sha = archive_sha.removeprefix("sha256:")
    if not SHA.fullmatch(archive_sha) or digest_file(archive)["sha256"] != archive_sha:
        raise ValueError("downloaded artifact digest does not match upload")
    with zipfile.ZipFile(archive) as data:
        entries = data.infolist()
        if len(entries) != 3 or {item.filename for item in entries} != set(expected):
            raise ValueError("uploaded archive differs from the verified file list")
        if sum(item.file_size for item in entries) > MAX_TOTAL:
            raise ValueError("archive expands beyond size limit")
        for item in entries:
            verify_entry(data, item, expected)
    if digest_file(archive)["sha256"] != archive_sha:
        raise ValueError("archive changed while being checked")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("capture", "seal", "select", "archive"))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--proof", type=Path, required=True)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--proof-sha", default="")
    parser.add_argument("--archive-sha", default="")
    args = parser.parse_args()
    try:
        if args.mode == "capture":
            write(
                args.proof,
                {
                    "schema": 1,
                    "phase": "before",
                    "identity": identity(),
                    "files": snapshot(args.directory),
                },
            )
        elif args.mode == "seal":
            data = load(args.before, "before")
            compare(args.directory, data)
            data["phase"] = "passed"
            write(args.proof, data)
        elif args.mode == "select":
            select(args.directory, args.proof)
        else:
            verify_archive(args.archive, args.proof, args.proof_sha, args.archive_sha)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f"GPU producer proof: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
