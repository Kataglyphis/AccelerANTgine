#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci_common.sh"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
RUNNER="ubuntu-24.04"
MATRIX_ARCH="x64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --runner) RUNNER="${2:-}"; shift 2 ;;
    --arch) MATRIX_ARCH="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

git config --global --add safe.directory "${WORKSPACE_DIR}" || true

info "Compiler: ${COMPILER}"
info "Runner: ${RUNNER}"
info "Arch: ${MATRIX_ARCH}"

if command -v uv >/dev/null 2>&1; then
  uv --version
else
  die "uv not found in container"
fi

mkdir -p "${WORKSPACE_DIR}/docs/coverage"
mkdir -p "${WORKSPACE_DIR}/docs/test-results"
