#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
RUNNER="ubuntu-26.04"
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

# No `git config --global --add safe.directory` here any more. It was registered
# twice: cmake_build_prepare_env and ctest_run_prepare_env both do it, and
# ci-build-and-test.sh points both at the real WORKSPACE_DIR (:84-85), as does
# ci-release.sh. A second copy in the one script that runs no git command at all
# was the copy most likely to drift from the others.

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
