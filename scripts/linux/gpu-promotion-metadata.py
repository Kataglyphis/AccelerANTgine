#!/usr/bin/env python3
"""Pass one matrix row's immutable artifact identity between trusted CI jobs."""

import argparse
import json
import os
import re
from pathlib import Path

TUPLES = {("nvidia", "x64"), ("nvidia", "arm64"), ("amd", "x64")}
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~-]*\Z")
NUMBER = re.compile(r"[1-9][0-9]*\Z")
SHA = re.compile(r"(?:sha256:)?[0-9a-f]{64}\Z")
KEYS = {
    "repository",
    "revision",
    "run_id",
    "run_attempt",
    "vendor",
    "arch",
    "artifact_id",
    "artifact_digest",
    "files",
}


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate metadata key")
        result[key] = value
    return result


def identity():
    env = os.environ
    data = {
        key: env[value]
        for key, value in {
            "repository": "GITHUB_REPOSITORY",
            "revision": "GITHUB_SHA",
            "run_id": "GITHUB_RUN_ID",
            "run_attempt": "GITHUB_RUN_ATTEMPT",
            "vendor": "GPU_VENDOR",
            "arch": "GPU_ARCH",
        }.items()
    }
    if (data["vendor"], data["arch"]) not in TUPLES:
        raise ValueError("unsupported Linux GPU tuple")
    if not NUMBER.fullmatch(data["run_id"]) or not NUMBER.fullmatch(
        data["run_attempt"]
    ):
        raise ValueError("invalid run identity")
    if not re.fullmatch(
        r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", data["repository"]
    ) or not re.fullmatch(r"[0-9a-f]{40}", data["revision"]):
        raise ValueError("invalid repository or revision")
    return data


def validate_files(files):
    if (
        not isinstance(files, list)
        or len(files) != 3
        or any(not isinstance(name, str) or not NAME.fullmatch(name) for name in files)
    ):
        raise ValueError("expected three portable flat package names")
    if len({name.casefold() for name in files}) != 3:
        raise ValueError("duplicate package names")
    if sorted(
        next(
            (
                suffix
                for suffix in (".deb", ".tar.gz", ".AppImage")
                if name.endswith(suffix)
            ),
            "",
        )
        for name in files
    ) != sorted((".deb", ".tar.gz", ".AppImage")):
        raise ValueError("expected one DEB, tarball and AppImage")
    return sorted(files)


def output(data):
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
        stream.write(
            f"artifact_id={data['artifact_id']}\nartifact_digest={data['artifact_digest']}\n"
        )
        stream.write(
            "files<<GPU_PACKAGE_FILES\n"
            + "\n".join(data["files"])
            + "\nGPU_PACKAGE_FILES\n"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("select", "create", "resolve"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    expected = identity()
    if args.mode == "select":
        files = []
        for pattern in ("*.deb", "*.tar.gz", "*.AppImage"):
            matches = list(args.path.glob(pattern))
            if len(matches) != 1 or matches[0].is_symlink() or not matches[0].is_file():
                raise ValueError("expected one regular package per format")
            files.append(matches[0].name)
        files = validate_files(files)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
            stream.write(
                "files<<GPU_PACKAGE_FILES\n"
                + "\n".join(files)
                + "\nGPU_PACKAGE_FILES\n"
            )
        return
    if args.mode == "create":
        data = {
            **expected,
            "artifact_id": os.environ["GPU_ARTIFACT_ID"],
            "artifact_digest": os.environ["GPU_ARTIFACT_DIGEST"],
            "files": os.environ["GPU_ARTIFACT_FILES"].splitlines(),
        }
    else:
        data = json.loads(
            args.path.read_text(encoding="utf-8"), object_pairs_hook=unique
        )
    if (
        not isinstance(data, dict)
        or set(data) != KEYS
        or any(data.get(key) != value for key, value in expected.items())
    ):
        raise ValueError("metadata identity does not match this tuple and run attempt")
    if (
        not isinstance(data["artifact_id"], str)
        or not NUMBER.fullmatch(data["artifact_id"])
        or not isinstance(data["artifact_digest"], str)
        or not SHA.fullmatch(data["artifact_digest"])
    ):
        raise ValueError("invalid artifact ID or digest")
    data["files"] = validate_files(data["files"])
    if args.mode == "create":
        with args.path.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream, sort_keys=True)
            stream.write("\n")
    else:
        output(data)


if __name__ == "__main__":
    main()
