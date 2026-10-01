#!/usr/bin/env bash
# ci-build-and-test.sh - the preset mapping and clang fuzz/TSan lane over ANTfrastructure's cmake-build.sh and ctest-run.sh.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source (via ci-common.sh) honours the ANTFRASTRUCTURE_DIR override.
antfrastructure_source linux/scripts/lib/cmake-build.sh
antfrastructure_source linux/scripts/lib/ctest-run.sh

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
BUILD_TYPE="Debug"
GCC_DEBUG_PRESET="linux-debug-GNU"
CLANG_DEBUG_PRESET="linux-debug-clang"
CLANG_TSAN_PRESET="linux-debug-clang-tsan"
TSAN_BUILD_DIR="build_tsan"
# Empty means <build-dir>/profraw; ci-coverage.sh must read the same directory.
PROFRAW_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --build-type) BUILD_TYPE="${2:-}"; shift 2 ;;
    --gcc-debug-preset) GCC_DEBUG_PRESET="${2:-}"; shift 2 ;;
    --clang-debug-preset) CLANG_DEBUG_PRESET="${2:-}"; shift 2 ;;
    --clang-tsan-preset) CLANG_TSAN_PRESET="${2:-}"; shift 2 ;;
    --tsan-build-dir) TSAN_BUILD_DIR="${2:-}"; shift 2 ;;
    --profraw-dir) PROFRAW_DIR="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
PROFRAW_DIR="${PROFRAW_DIR:-${BUILD_DIR}/profraw}"

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

# The libraries default safe.directory to /workspace, which is wrong outside the container.
CMAKE_BUILD_SAFE_DIRECTORY="${WORKSPACE_DIR}"
CTEST_RUN_SAFE_DIRECTORY="${WORKSPACE_DIR}"

# `cmake -B` overrides the preset's binaryDir, so ctest always runs the tree just built.
info "Using preset: ${PRESET}"
# About 2 GB per TU; the 4000 MB default would halve the job count on memory-capped runners.
cmake_build_main --preset "${PRESET}" --build-dir "${BUILD_DIR}" --mb-per-job 2000

# %p gives every instrumented test process its own profile instead of one overwritten default.profraw (AGENTS.md section 4).
if [[ "${COMPILER}" == "clang" ]]; then
  mkdir -p "${PROFRAW_DIR}"
  PROFRAW_DIR="$(cd "${PROFRAW_DIR}" && pwd)"
  find "${PROFRAW_DIR}" -maxdepth 1 -type f -name '*.profraw' -delete
  export LLVM_PROFILE_FILE="${PROFRAW_DIR}/%p.profraw"
  info "Coverage profiles go to ${LLVM_PROFILE_FILE}"
fi

# Subshell: ctest_run_execute cds in the caller's shell, and the TSan run must start from the root.
(
  ctest_run_main \
    --build-dir "${BUILD_DIR}" \
    --build-type "${BUILD_TYPE}" \
    -- --output-junit "${WORKSPACE_DIR}/docs/test_results.xml" --no-tests=error
)

if [[ "${COMPILER}" == "clang" ]]; then
  # Not optional: the clang debug preset always configures Test/fuzz, so a missing binary is a broken build.
  FUZZ_TEST="${BUILD_DIR}/fuzzTestSuite"
  if [[ ! -x "${FUZZ_TEST}" ]]; then
    die "Fuzz test binary '${FUZZ_TEST}' is missing or not executable, but preset '${PRESET}' configures Test/fuzz for Clang+Debug. The build did not produce it."
  fi
  "${FUZZ_TEST}"

  # The coverage set ends here; the TSan tree is not instrumented.
  unset LLVM_PROFILE_FILE

  info "=== Running additional build with TSan ==="
  info "Using preset: ${CLANG_TSAN_PRESET}"
  # Subshell: cmake_build_parse_args overwrites the globals BUILD_DIR, PRESET and PARALLEL_JOBS.
  (
    cmake_build_main --preset "${CLANG_TSAN_PRESET}" --build-dir "${TSAN_BUILD_DIR}" --mb-per-job 2000
  )

  # GLib and GStreamer are uninstrumented and hand buffers between threads through futexes TSan cannot see.
  (
    export TSAN_OPTIONS="ignore_noninstrumented_modules=1${TSAN_OPTIONS:+:${TSAN_OPTIONS}}"
    ctest_run_main \
      --build-dir "${TSAN_BUILD_DIR}" \
      --build-type "${BUILD_TYPE}" \
      -- --output-junit "${WORKSPACE_DIR}/docs/test_results_tsan.xml" --no-tests=error
  )
else
  info "Compiled with GCC so no fuzz testing or TSan!"
fi
