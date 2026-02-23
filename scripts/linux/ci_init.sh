#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"

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
