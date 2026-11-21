#!/usr/bin/env bash
# CMakeLists.txt's project() VERSION is the one version: the wheel's regex and the hub's version_util.sh must agree.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
version_util="${root}/third_party/ANTfrastructure/linux/scripts/02-toolchain/rust/version_util.sh"

# Usage: wheel_version CMAKELISTS; what scikit-build-core's regex provider reads there with pyproject.toml's settings.
wheel_version() {
  python3 -I - "${root}/pyproject.toml" "$1" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    settings = tomllib.load(handle)
project, version = settings["project"], settings["tool"]["scikit-build"]["metadata"]["version"]
if "version" in project or "version" not in project.get("dynamic", []):
    sys.exit("pyproject.toml states a version of its own")
if version["provider"] != "scikit_build_core.metadata.regex" or version["input"] != "CMakeLists.txt":
    sys.exit(f"the wheel's version comes from elsewhere: {version}")
with open(sys.argv[2], encoding="utf-8") as handle:
    match = re.search(version["regex"], handle.read(), re.MULTILINE)
print(match.group("value") if match else "")
PY
}

# Usage: agree CMAKELISTS [WANT]; both readers name the same non-empty version, and WANT when given.
agree() {
  local wheel hub
  wheel=$(wheel_version "$1") || return 1
  hub=$(bash "${version_util}" --file-version "$1") || hub=''
  printf 'wheel %s, version_util %s\n' "${wheel:-<none>}" "${hub:-<none>}" > "${work}/out"
  if [[ -n "${wheel}" && "${wheel}" == "${hub}" && "${wheel}" == "${2:-${wheel}}" ]]; then return 0; fi
  return 1
}

suite_expect pass 'the wheel and version_util.sh read the same version from this CMakeLists.txt' agree "${root}/CMakeLists.txt"

printf 'cmake_minimum_required(VERSION 3.31.6)\nproject(Fixture VERSION 1.20.3 LANGUAGES CXX)\n' > "${work}/CMakeLists.txt"
suite_expect pass "project()'s VERSION, not cmake_minimum_required's" agree "${work}/CMakeLists.txt" 1.20.3

printf 'cmake_minimum_required(VERSION 3.31.6)\n\nproject(\n  Fixture\n  DESCRIPTION "a fixture"\n  VERSION 2.0.1\n  LANGUAGES CXX)\n' \
  > "${work}/CMakeLists.txt"
suite_expect pass 'a project() over several lines, VERSION after DESCRIPTION' agree "${work}/CMakeLists.txt" 2.0.1

printf 'cmake_minimum_required(VERSION 3.31.6)\nproject(Fixture LANGUAGES CXX)\nset(VERSION 9.9)\n' > "${work}/CMakeLists.txt"
no_version() {
  if [[ -z "$(wheel_version "${work}/CMakeLists.txt")" ]]; then return 0; fi
  return 1
}
suite_expect pass 'a project() without VERSION gives the wheel none, so its build fails instead of guessing' no_version

# uv omits a dynamic version from the lock; a version it does record must be this one.
lock_agrees() {
  python3 -I - "${root}/uv.lock" "$(wheel_version "${root}/CMakeLists.txt")" > "${work}/out" 2>&1 <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    lock = tomllib.load(handle)
root = [package for package in lock["package"] if package["name"] == "kataglyphis-inference"]
if len(root) != 1:
    sys.exit(f"uv.lock holds {len(root)} kataglyphis-inference entries")
if root[0].get("version", sys.argv[2]) != sys.argv[2]:
    sys.exit(f"uv.lock records {root[0]['version']}, CMakeLists.txt states {sys.argv[2]}: relock")
PY
}
suite_expect pass "uv.lock records no other version of this package" lock_agrees

suite_finish version-single-source
echo 'version single source: all cases passed'
