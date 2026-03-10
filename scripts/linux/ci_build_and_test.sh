#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci_common.sh"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
BUILD_TYPE="Debug"
GCC_DEBUG_PRESET="linux-debug-GNU"
CLANG_DEBUG_PRESET="linux-debug-clang"
CLANG_TSAN_PRESET="linux-debug-clang-tsan"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --build-type) BUILD_TYPE="${2:-}"; shift 2 ;;
    --gcc-debug-preset) GCC_DEBUG_PRESET="${2:-}"; shift 2 ;;
    --clang-debug-preset) CLANG_DEBUG_PRESET="${2:-}"; shift 2 ;;
    --clang-tsan-preset) CLANG_TSAN_PRESET="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

case "${COMPILER}" in
  gcc)
    PRESET="${GCC_DEBUG_PRESET}"
    ;;
  clang)
    PRESET="${CLANG_DEBUG_PRESET}"
    ;;
  *)
    die "Unsupported COMPILER='${COMPILER}'. Expected 'gcc' or 'clang'."
    ;;
esac

# Use cgroup-aware parallelism for the build
JOBS="$(compute_jobs_with_mem_cap)"
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
info "Build parallelism: ${JOBS} jobs (cgroup + memory aware)"

info "Using preset: ${PRESET}"
cmake --preset "${PRESET}"
cmake --build --preset "${PRESET}"

# Keep ctest test-dir aligned with preset binaryDir.
if [[ "${PRESET}" == "${CLANG_DEBUG_PRESET}" || "${PRESET}" == "${GCC_DEBUG_PRESET}" ]]; then
  BUILD_DIR="build"
fi

(cd "${BUILD_DIR}" && ctest -C "${BUILD_TYPE}" --verbose --extra-verbose --debug -T test --output-on-failure --output-junit "${WORKSPACE_DIR}/docs/test_results.xml")

if [[ "${COMPILER}" == "clang" ]]; then
  if [[ -x "./${BUILD_DIR}/first_fuzz_test" ]]; then
    "./${BUILD_DIR}/first_fuzz_test"
  else
    warn "first_fuzz_test not found/executable, skipping"
  fi

  info "=== Running additional build with TSan ==="
  TSAN_PRESET="${CLANG_TSAN_PRESET}"
  TSAN_BUILD_DIR="build_tsan"

  info "Using preset: ${TSAN_PRESET}"
  cmake --preset "${TSAN_PRESET}"
  cmake --build --preset "${TSAN_PRESET}"

  (cd "${TSAN_BUILD_DIR}" && ctest -C "${BUILD_TYPE}" --verbose --extra-verbose --debug -T test --output-on-failure --output-junit "${WORKSPACE_DIR}/docs/test_results_tsan.xml")
else
  info "Compiled with GCC so no fuzz testing or TSan!"
fi
