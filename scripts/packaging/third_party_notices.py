#!/usr/bin/env python3
# Copyright (c) 2026 Jonas Heinle
# SPDX-License-Identifier: MIT
"""Write the third-party notices of one installed package tree; fail on any binary with no license source."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

PE_SUFFIXES = (".dll", ".exe", ".pyd")
COMMON_LICENSE = re.compile(
    r"/usr/share/common-licenses/([A-Za-z0-9](?:[A-Za-z0-9.+_-]*[A-Za-z0-9+])?)"
)
MAX_TEXT_BYTES = 8 * 1024 * 1024


class NoticeError(Exception):
    """A shipped binary or license text that cannot be accounted for."""


@dataclass
class Component:
    """One third-party component as it appears in the generated list."""

    ident: str
    name: str
    version: str
    spdx: str
    url: str = ""
    source: str = ""
    notice: str = ""
    files: list[str] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)


def read_env_file(path: Path) -> dict[str, str]:
    """Read KEY=VALUE lines the way versions.env writes them."""
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def parse_pairs(items: list[str], what: str) -> dict[str, str]:
    """Split NAME=VALUE command-line pairs."""
    result: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise NoticeError(f"{what} needs NAME=VALUE: {item}")
        key, value = item.split("=", 1)
        result[key] = value
    return result


def is_elf(path: Path) -> bool:
    """Return whether the file starts with the ELF magic."""
    with path.open("rb") as stream:
        return stream.read(4) == b"\x7fELF"


def shipped_binaries(root: Path, platform: str) -> list[Path]:
    """List regular binary files; symlinks share their target's notice."""
    found: list[Path] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if platform == "windows":
            if path.suffix.lower() in PE_SUFFIXES:
                found.append(path)
        elif is_elf(path):
            found.append(path)
    return found


def matches(name: str, patterns: list[str], platform: str) -> bool:
    """Match a file name; Windows names are case-insensitive."""
    if platform == "windows":
        return any(
            fnmatch.fnmatch(name.lower(), pattern.lower()) for pattern in patterns
        )
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)


def platform_texts(entry: dict[str, Any], platform: str) -> list[dict[str, str]]:
    """Texts are one list, or one list per platform."""
    texts = entry.get("texts", [])
    if isinstance(texts, dict):
        texts = texts.get(platform, [])
    if not isinstance(texts, list):
        raise NoticeError(f"{entry['id']}: texts must be a list")
    return texts


def resolve_version(entry: dict[str, Any], variables: dict[str, str]) -> str:
    """Prefer a pinned variable so the list cannot drift from the build."""
    variable = entry.get("version_var")
    if variable:
        if variable not in variables:
            raise NoticeError(
                f"{entry['id']}: version variable {variable} is not defined"
            )
        return variables[variable]
    return str(entry.get("version", ""))


def validate_inventory(inventory: dict[str, Any]) -> None:
    """Reject a malformed manifest before any tree is classified."""
    if inventory.get("version") != 1 or not isinstance(
        inventory.get("components"), list
    ):
        raise NoticeError("components manifest needs version 1 and a components list")
    seen: set[str] = set()
    for entry in inventory["components"]:
        if not isinstance(entry, dict) or not all(
            isinstance(entry.get(key), str) and entry[key]
            for key in ("id", "name", "spdx")
        ):
            raise NoticeError(f"component needs id, name and spdx: {entry!r}")
        if entry["id"] in seen:
            raise NoticeError(f"duplicate component id: {entry['id']}")
        seen.add(entry["id"])


def read_text(path: Path, owner: str) -> bytes:
    """Refuse a missing, linked, empty or oversized license text."""
    if path.is_symlink() and not path.resolve().is_file():
        raise NoticeError(f"{owner}: license text is a dangling link: {path}")
    if not path.is_file():
        raise NoticeError(f"{owner}: license text is missing: {path}")
    data = path.read_bytes()
    if len(data) > MAX_TEXT_BYTES or not data.strip():
        raise NoticeError(f"{owner}: license text is empty or too large: {path}")
    return data


class Stager:
    """Collect components and write their texts below the destination."""

    def __init__(self, args: argparse.Namespace) -> None:
        """Load the inventory and the version variables."""
        self.args = args
        self.root: Path = args.root.resolve()
        self.dest: Path = args.dest
        self.platform: str = args.platform
        self.roots = {
            "repo": args.repo.resolve(),
            "install": self.root,
            **{
                key: Path(value)
                for key, value in parse_pairs(args.text_root, "--text-root").items()
            },
        }
        self.variables: dict[str, str] = {}
        for env_file in args.versions_env:
            self.variables.update(read_env_file(env_file))
        self.variables.update(parse_pairs(args.define, "--define"))
        self.inventory = json.loads(args.manifest.read_text(encoding="utf-8"))
        validate_inventory(self.inventory)
        self.components: dict[str, Component] = {}
        self.unaccounted: list[str] = []
        self.common_licenses: set[str] = set()

    def relative(self, path: Path) -> str:
        """Paths in the list are relative to the package root."""
        return path.relative_to(self.root).as_posix()

    def component(self, entry: dict[str, Any]) -> Component:
        """Create or reuse the listed component for an inventory entry."""
        ident = entry["id"]
        if ident not in self.components:
            component = Component(
                ident,
                entry["name"],
                resolve_version(entry, self.variables),
                entry["spdx"],
                entry.get("url", ""),
                entry.get("source", ""),
                entry.get("notice", ""),
            )
            texts = platform_texts(entry, self.platform)
            if not texts and not component.notice:
                raise NoticeError(f"{ident}: needs license texts or a notice")
            for text in texts:
                self.add_text(component, text)
            self.components[ident] = component
        return self.components[ident]

    def add_text(self, component: Component, text: dict[str, str]) -> None:
        """Installed texts are referenced in place; every other text is copied beside the list."""
        root_name, relative = text.get("root"), text.get("path")
        if root_name not in self.roots or not relative:
            raise NoticeError(
                f"{component.ident}: unknown text root {root_name!r} or empty path"
            )
        source = self.roots[root_name] / relative
        data = read_text(source, component.ident)
        if root_name == "install":
            component.texts.append(self.relative(source))
            return
        target = self.dest / "third-party" / component.ident / Path(relative).name
        if target.exists() and target.read_bytes() != data:
            raise NoticeError(
                f"{component.ident}: two different texts share the name {target.name}"
            )
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        component.texts.append(self.relative(target))

    def match_inventory(self, name: str) -> dict[str, Any] | None:
        """First listed component wins, so specific patterns precede broad ones."""
        for entry in self.inventory["components"]:
            if matches(name, entry.get("binaries", []), self.platform):
                return entry
        return None

    def dpkg_owner(self, name: str) -> str | None:
        """Find the package that owns the library the closure copied, searched as the closure searches."""
        for directory in self.args.search:
            candidate = directory / name
            if not candidate.exists():
                continue
            for path in (candidate, candidate.resolve()):
                result = subprocess.run(
                    [self.args.dpkg, "-S", str(path)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if result.returncode == 0 and result.stdout.strip():
                    return result.stdout.splitlines()[0].split(":", 1)[0].strip()
            return None
        return None

    def deb_component(self, package: str) -> Component:
        """List a Debian package with its copyright file and the common licenses it cites."""
        ident = f"deb-{package}"
        if ident not in self.components:
            result = subprocess.run(
                [self.args.dpkg_query, "-W", "-f=${Version}", package],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode != 0 or not result.stdout.strip():
                raise NoticeError(f"{package}: dpkg-query has no version")
            copyright_file = self.args.doc_root / package / "copyright"
            data = read_text(copyright_file, package)
            component = Component(
                ident,
                package,
                result.stdout.strip(),
                "see copyright",
                f"https://packages.ubuntu.com/search?keywords={package}",
                f"the distribution's {package} source package",
            )
            target = self.dest / "third-party" / ident / "copyright"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            component.texts.append(self.relative(target))
            for license_name in sorted(
                set(COMMON_LICENSE.findall(data.decode("utf-8", "replace")))
            ):
                self.common_licenses.add(license_name)
                component.texts.append(
                    f"{self.relative(self.dest)}/third-party/common-licenses/{license_name}"
                )
            self.components[ident] = component
        return self.components[ident]

    def copy_common_licenses(self) -> None:
        """Debian copyright files cite these by path; the package must carry them."""
        for license_name in sorted(self.common_licenses):
            source = self.args.common_licenses / license_name
            if source.is_dir():
                continue
            data = read_text(source, f"common license {license_name}")
            target = self.dest / "third-party" / "common-licenses" / license_name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

    def classify(self, binary: Path) -> None:
        """Attribute one shipped binary or record it as unaccounted."""
        name = binary.name
        if matches(name, self.inventory.get("project_binaries", []), self.platform):
            return
        package = (
            self.dpkg_owner(name)
            if self.args.dpkg and self.platform == "linux"
            else None
        )
        if package:
            self.deb_component(package).files.append(self.relative(binary))
            return
        entry = self.match_inventory(name)
        if entry is None:
            self.unaccounted.append(self.relative(binary))
            return
        self.component(entry).files.append(self.relative(binary))

    def add_linked(self) -> None:
        """Statically linked components ship inside the project's own binaries."""
        for entry in self.inventory["components"]:
            if self.args.scope in entry.get("linked", []):
                self.component(entry).files.append(
                    "(statically linked into this project's binaries)"
                )

    def add_cargo(self) -> None:
        """Delegate the Cargo graph to ANTfrastructure's collector, then list each crate."""
        if not self.args.cargo_stager:
            return
        with tempfile.TemporaryDirectory(prefix="cargo-notices-") as temporary:
            output = Path(temporary) / "crates"
            command = [
                sys.executable,
                str(self.args.cargo_stager),
                "--workspace",
                str(self.args.cargo_workspace),
                "--root-package",
                self.args.cargo_root_package,
                "--target",
                self.args.cargo_target,
                "--policy",
                str(self.args.cargo_policy),
                "--output-dir",
                str(output),
            ]
            if self.args.cargo_metadata:
                command += ["--metadata", str(self.args.cargo_metadata)]
            result = subprocess.run(
                command, check=False, capture_output=True, text=True
            )
            if result.returncode != 0:
                raise NoticeError(
                    f"Cargo license collection failed: {result.stderr.strip() or result.stdout.strip()}"
                )
            manifest = json.loads(
                (output / "manifest.json").read_text(encoding="utf-8")
            )
            for package in manifest["packages"]:
                if package["name"] == self.args.cargo_root_package:
                    continue
                ident = f"crate-{package['name']}"
                component = Component(
                    ident,
                    f"{package['name']} (Rust crate)",
                    package["version"],
                    package.get("license") or "see license files",
                    package.get("repository") or "",
                    package.get("source") or "",
                )
                component.files.append(
                    "(in the Cargo dependency graph of this project's Rust static library)"
                )
                for item in package["files"]:
                    data = read_text(output / item["path"], ident)
                    target = self.dest / "third-party" / ident / Path(item["path"]).name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    component.texts.append(self.relative(target))
                if not component.texts:
                    raise NoticeError(
                        f"{ident}: Cargo collector returned no license text"
                    )
                self.components[ident] = component

    def write(self) -> Path:
        """Write the human list and the machine inventory."""
        ordered = sorted(self.components.values(), key=lambda item: item.name.lower())
        lines = [
            f"{self.args.project} third-party notices",
            "",
            "This package contains the open-source and redistributable components listed below.",
            "License text paths are relative to the package's installation root.",
            f"{self.args.project}'s own license: {self.args.project_license}",
            "",
        ]
        for component in ordered:
            lines.append(component.name)
            if component.version:
                lines.append(f"  Version: {component.version}")
            lines.append(f"  License: {component.spdx}")
            if component.url:
                lines.append(f"  Homepage: {component.url}")
            if component.source:
                lines.append(f"  Source: {component.source}")
            if component.notice:
                lines.append(f"  Notice: {component.notice}")
            lines.extend(f"  File: {item}" for item in sorted(set(component.files)))
            lines.extend(f"  License text: {item}" for item in component.texts)
            lines.append("")
        notices = self.dest / "THIRD-PARTY-NOTICES.txt"
        notices.write_text("\n".join(lines), encoding="utf-8", newline="\n")
        inventory = [
            {
                "id": item.ident,
                "name": item.name,
                "version": item.version,
                "license": item.spdx,
                "url": item.url,
                "source": item.source,
                "notice": item.notice,
                "files": sorted(set(item.files)),
                "texts": item.texts,
            }
            for item in ordered
        ]
        (self.dest / "third-party-inventory.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "scope": self.args.scope,
                    "platform": self.platform,
                    "components": inventory,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
            newline="\n",
        )
        return notices

    def run(self) -> Path:
        """Classify the tree and fail when any binary is unaccounted for."""
        if not self.root.is_dir():
            raise NoticeError(f"package root is not a directory: {self.root}")
        if self.dest.exists() and not self.dest.is_dir():
            raise NoticeError(f"destination is not a directory: {self.dest}")
        self.dest = self.dest.resolve()
        stale = self.dest / "third-party"
        if stale.exists():
            shutil.rmtree(stale)
        self.dest.mkdir(parents=True, exist_ok=True)
        if not (self.root / self.args.project_license).is_file():
            raise NoticeError(
                f"project license is not installed: {self.args.project_license}"
            )
        binaries = shipped_binaries(self.root, self.platform)
        if not any(
            matches(
                path.name, self.inventory.get("project_binaries", []), self.platform
            )
            for path in binaries
        ):
            raise NoticeError(
                f"no project binary in {self.root}; refusing an empty notice list"
            )
        for binary in binaries:
            self.classify(binary)
        if self.unaccounted:
            raise NoticeError(
                "binaries with no license source: " + ", ".join(self.unaccounted)
            )
        self.add_linked()
        self.add_cargo()
        self.copy_common_licenses()
        return self.write()


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--root", type=Path, required=True, help="installed package tree"
    )
    parser.add_argument(
        "--dest",
        type=Path,
        required=True,
        help="directory for the notices, inside --root",
    )
    parser.add_argument("--platform", choices=("linux", "windows"), required=True)
    parser.add_argument("--scope", choices=("native", "wheel"), default="native")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--project", default="AccelerANTgine")
    parser.add_argument(
        "--project-license",
        required=True,
        help="the project license, relative to --root",
    )
    parser.add_argument(
        "--text-root",
        action="append",
        default=[],
        help="NAME=DIR for manifest text roots",
    )
    parser.add_argument("--versions-env", type=Path, action="append", default=[])
    parser.add_argument(
        "--define", action="append", default=[], help="KEY=VALUE version variable"
    )
    parser.add_argument(
        "--search",
        type=Path,
        action="append",
        default=[],
        help="closure search directory",
    )
    parser.add_argument(
        "--dpkg", default="", help="dpkg executable; empty disables the Debian lookup"
    )
    parser.add_argument("--dpkg-query", default="dpkg-query")
    parser.add_argument("--doc-root", type=Path, default=Path("/usr/share/doc"))
    parser.add_argument(
        "--common-licenses", type=Path, default=Path("/usr/share/common-licenses")
    )
    parser.add_argument("--cargo-stager", type=Path)
    parser.add_argument("--cargo-workspace", type=Path)
    parser.add_argument("--cargo-root-package", default="")
    parser.add_argument("--cargo-target", default="")
    parser.add_argument("--cargo-policy", type=Path)
    parser.add_argument(
        "--cargo-metadata", type=Path, help="precomputed metadata, for tests"
    )
    args = parser.parse_args(argv)
    if args.cargo_stager and not (
        args.cargo_workspace
        and args.cargo_root_package
        and args.cargo_target
        and args.cargo_policy
    ):
        parser.error(
            "--cargo-stager needs --cargo-workspace, --cargo-root-package, --cargo-target and --cargo-policy"
        )
    try:
        args.dest.resolve().relative_to(args.root.resolve())
    except ValueError:
        parser.error("--dest must be inside --root")
    return args


def main(argv: list[str]) -> int:
    """Entry point."""
    args = parse_args(argv)
    try:
        notices = Stager(args).run()
    except (NoticeError, OSError, json.JSONDecodeError, UnicodeError) as error:
        print(f"FAIL: third-party notices: {error}", file=sys.stderr)
        return 1
    print(f"PASS: third-party notices: {notices}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
