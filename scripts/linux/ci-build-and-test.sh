#!/usr/bin/env bash
# ci-build-and-test.sh - project wrapper around ContainerHub's generic CMake
# build driver (linux/scripts/lib/cmake-build.sh) and its ctest runner
# (linux/scripts/lib/ctest-run.sh).
#
# What was hand-written here and now comes from the libraries:
#   * the memory-aware job count           -> cmake_build_jobs
#   * cmake --preset + cmake --build       -> cmake_build_run
#   * the ctest flag string
#     "--verbose --extra-verbose --debug -T test --output-on-failure", which is
#     character-for-character _CTEST_RUN_BUILTIN_ARGS in ctest-run.sh
#                                          -> ctest_run_execute
#
# The reason this is not a line-count exercise is cmake_build_prepare_env, which
# this repo had no equivalent of anywhere (ci-init.sh only marks the workspace
# git-safe). It additionally:
#   1. neutralises the image's CCACHE_SECONDARY_STORAGE=true - that variable is
#      ccache's remote_storage and must be a URL, so ccache dies with
#      "URL scheme must not be empty: true" on every compile. sccache ignores it,
#      so only the gcc presets were hit; upstream documents this as having held
#      the gcc lanes red for months.
#   2. falls back to a writable CARGO_HOME / SCCACHE_DIR / CCACHE_DIR when the
#      image's root-owned defaults are unwritable for the non-root CI user - the
#      sccache exit-254 failure that was red 2026-07-28 to 2026-08-02.
#   3. marks the workspace git-safe.
#
# What stays here is genuinely project-specific: this repo's CLI (ci-run-all.sh
# and linux_run.yml drive it), the compiler -> preset mapping, and the
# clang-only fuzz/TSan lane.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

CMAKE_BUILD_LIB="${_SCRIPT_DIR}/../../third_party/ContainerHub/linux/scripts/lib/cmake-build.sh"
if [[ ! -f "${CMAKE_BUILD_LIB}" ]]; then
  die "Shared cmake-build library not found at '${CMAKE_BUILD_LIB}'. Initialize the ContainerHub submodule first."
fi
# shellcheck disable=SC1091
source "${CMAKE_BUILD_LIB}"

CTEST_RUN_LIB="${_SCRIPT_DIR}/../../third_party/ContainerHub/linux/scripts/lib/ctest-run.sh"
if [[ ! -f "${CTEST_RUN_LIB}" ]]; then
  die "Shared ctest-run library not found at '${CTEST_RUN_LIB}'. Initialize the ContainerHub submodule first."
fi
# shellcheck disable=SC1091
source "${CTEST_RUN_LIB}"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
BUILD_TYPE="Debug"
GCC_DEBUG_PRESET="linux-debug-GNU"
CLANG_DEBUG_PRESET="linux-debug-clang"
CLANG_TSAN_PRESET="linux-debug-clang-tsan"
TSAN_BUILD_DIR="build_tsan"

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

# Both libraries default their git safe.directory to /workspace. That is right
# for the containerized lane and wrong for a dev box or a differently mounted
# workspace, and this script already knows the real path.
CMAKE_BUILD_SAFE_DIRECTORY="${WORKSPACE_DIR}"
CTEST_RUN_SAFE_DIRECTORY="${WORKSPACE_DIR}"

# The preset/binaryDir alignment hack this file used to carry - "if PRESET is the
# clang or gcc debug preset then BUILD_DIR=build" - is gone, not merely moved:
# cmake_build_run configures with `cmake -B "${BUILD_DIR}" --preset ...`, so the
# command line overrides the preset's binaryDir, and the tree ctest_run_execute
# cds into is by construction the tree that was just built. Restating
# CMakePresets.json's binaryDir values in a shell conditional was the thing that
# could drift.
info "Using preset: ${PRESET}"
# --mb-per-job 2000: the per-job RAM cap the pre-library jobs computation used
# (parallelism.sh generic profile, ~2GB/TU); cmake-build.sh's 4000 default
# would silently halve the job count on memory-capped runners.
# --build-type reaches only ctest (-C): the Linux presets are single-config
# Ninja, so the buildPreset 'configuration' field is deliberately unforwarded -
# the configure preset already pins CMAKE_BUILD_TYPE.
cmake_build_main --preset "${PRESET}" --build-dir "${BUILD_DIR}" --mb-per-job 2000

# Subshell: ctest_run_execute cds into the build tree in the CALLER's shell (it
# is deliberately not subshelled upstream so the command stays inspectable), and
# the TSan run below has to start from the workspace root again.
(
  ctest_run_main \
    --build-dir "${BUILD_DIR}" \
    --build-type "${BUILD_TYPE}" \
    -- --output-junit "${WORKSPACE_DIR}/docs/test_results.xml"
)

if [[ "${COMPILER}" == "clang" ]]; then
  # first_fuzz_test is NOT optional on this lane. Test/fuzz/CMakeLists.txt
  # creates it for every Debug + Clang build on Linux, CMakeLists.txt adds
  # Test/fuzz whenever BUILD_TESTING is on (linux-common sets it TRUE), the
  # build type is Debug and the thread sanitizer is off - which is exactly the
  # clang debug preset used above - and CMAKE_RUNTIME_OUTPUT_DIRECTORY
  # (cmake/ProjectOptions.cmake) puts the binary at the top of the build tree.
  # So a missing binary means the build did not produce a target it was
  # configured to produce. This used to be `warn "... not found/executable,
  # skipping"`, which turned a broken fuzz build into a green CI run.
  FUZZ_TEST="${BUILD_DIR}/first_fuzz_test"
  if [[ ! -x "${FUZZ_TEST}" ]]; then
    die "Fuzz test binary '${FUZZ_TEST}' is missing or not executable, but preset '${PRESET}' configures Test/fuzz for Clang+Debug. The build did not produce it."
  fi
  "${FUZZ_TEST}"

  info "=== Running additional build with TSan ==="
  info "Using preset: ${CLANG_TSAN_PRESET}"
  # Subshell: cmake_build_parse_args assigns the lib-globals BUILD_DIR / PRESET /
  # PARALLEL_JOBS, and this second call would clobber the wrapper's own values -
  # harmless today, a landmine for any line added below that still reads them.
  (
    cmake_build_main --preset "${CLANG_TSAN_PRESET}" --build-dir "${TSAN_BUILD_DIR}" --mb-per-job 2000
  )

  (
    ctest_run_main \
      --build-dir "${TSAN_BUILD_DIR}" \
      --build-type "${BUILD_TYPE}" \
      -- --output-junit "${WORKSPACE_DIR}/docs/test_results_tsan.xml"
  )
else
  info "Compiled with GCC so no fuzz testing or TSan!"
fi
