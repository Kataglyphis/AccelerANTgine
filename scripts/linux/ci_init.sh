#!/usr/bin/env bash
set -euo pipefail

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
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

git config --global --add safe.directory "${WORKSPACE_DIR}" || true

echo "Compiler: ${COMPILER}"
echo "Runner: ${RUNNER}"
echo "Arch: ${MATRIX_ARCH}"

if command -v uv >/dev/null 2>&1; then
  uv --version
else
  echo "ERROR: uv not found in container" >&2
  exit 1
fi

mkdir -p "${WORKSPACE_DIR}/docs/coverage"
mkdir -p "${WORKSPACE_DIR}/docs/test-results"
