#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
hub="${work}/hub/linux/scripts"
mkdir -p "${hub}/01-core" "${hub}/lib"
cat > "${hub}/01-core/common.sh" <<'STUB'
info() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
FLATPAK_RUNTIME_VERSION=1
STUB
touch "${hub}/01-core/modules.sh" "${hub}/01-core/tool-checks.sh" \
  "${hub}/lib/cli-value-options.sh" "${hub}/lib/app-packaging.sh"
cat > "${hub}/lib/cmake-build.sh" <<'STUB'
cmake_build_main() { printf '%s\n' "$@" > "${TEST_CONFIGURE_LOG:?}"; exit 0; }
STUB
cat > "${hub}/lib/fetch-data-lock.py" <<'STUB'
import os
import sys
from pathlib import Path

if len(sys.argv) != 3 or sys.argv[1] != "--lock":
    raise SystemExit("expected a locked model input")
Path(os.environ["TEST_FETCH_LOG"]).write_text(sys.argv[2], encoding="utf-8")
STUB
export ANTFRASTRUCTURE_DIR="${work}/hub" TEST_CONFIGURE_LOG="${work}/configure" TEST_FETCH_LOG="${work}/fetch"
driver="${repo}/scripts/linux/ci-release.sh"
run() { /usr/bin/bash "$driver" "$@" >/dev/null 2>&1; }
run --no-flatpak || { echo 'CPU release was rejected' >&2; exit 1; }
[[ "$(cat "${TEST_FETCH_LOG}")" == "${PWD}/models/models.lock" ]] || { echo 'Locked model fetch was skipped' >&2; exit 1; }
if grep -q -- '-DKATAGLYPHIS_ORT_VARIANT=' "${TEST_CONFIGURE_LOG}"; then
  echo 'CPU release configure changed' >&2; exit 1
fi
for variant in nvidia amd; do
  run --ort-variant "$variant" --no-flatpak || { echo "${variant} release was rejected" >&2; exit 1; }
  grep -qx -- "-DKATAGLYPHIS_ORT_VARIANT=${variant}" "${TEST_CONFIGURE_LOG}" || {
    echo "${variant} configure flag is missing" >&2; exit 1;
  }
done
if run --ort-variant nvidia; then echo 'GPU Flatpak was accepted' >&2; exit 1; fi
if run --ort-variant bogus --no-flatpak; then echo 'invalid variant was accepted' >&2; exit 1; fi
if run --ort-variant; then echo 'missing variant was accepted' >&2; exit 1; fi
printf 'CPU and GPU release variant routing passed\n'
