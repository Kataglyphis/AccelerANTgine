#!/usr/bin/env bash
# ci-coverage.sh - project wrapper around ANTfrastructure's generic coverage driver
# (linux/scripts/lib/coverage.sh). Both backends - gcovr for GCC, llvm-cov for
# Clang - previously lived here as hand-written pipelines; only this project's
# report paths, filters and the name of the instrumented library remain.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source, not a "${_SCRIPT_DIR}/../../third_party/ANTfrastructure/..."
# literal: it resolves under ANTFRASTRUCTURE_DIR (which the literal ignored, so the
# bootstrap's environment override did nothing) and fails naming the probed path
# and the fix. In scope because ci-common.sh sources lib/antfrastructure.sh.
antfrastructure_source linux/scripts/lib/coverage.sh

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
COVERAGE_JSON="coverage.json"
# Where ci-build-and-test.sh had the instrumented runs write their raw profiles;
# empty means <build-dir>/profraw, the same default that script uses.
PROFRAW_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --coverage-json) COVERAGE_JSON="${2:-}"; shift 2 ;;
    --profraw-dir) PROFRAW_DIR="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
PROFRAW_DIR="${PROFRAW_DIR:-${BUILD_DIR}/profraw}"

# Project-specific: what to leave out of the report. Dependencies, generated
# _deps trees and the test code itself are not the thing under measurement.
COVERAGE_LLVM_IGNORE_REGEX=(".*/(third_party|build[^/]*/_deps|_deps|Test|tests|usr/include|usr/lib)/.*")

# The object whose coverage mapping llvm-cov reports: Src/ is compiled into this
# shared library (Src/CMakeLists.txt, add_library(${PROJECT_NAME} SHARED) with
# LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib), and the test suites only
# link it. llvm-cov reports the mapping of the object it is given and nothing
# else, so naming ./compileTestSuite here - as this line used to - reports the
# suite's own Test/ sources, which the ignore regex above then drops.
COVERAGE_OBJECT="lib/libAccelerANTgine.so"

if [[ "${COMPILER}" == "gcc" ]]; then
  # gcovr reads .gcda/.gcno from the compile directory, hence the cd; the paths
  # baked into .gcno are relative to it.
  COVERAGE_GCOVR_EXTRA_ARGS=(
    --config "${WORKSPACE_DIR}/gcovr.cfg"
    --filter "${WORKSPACE_DIR}/Src/.*"
    --html-details "${WORKSPACE_DIR}/docs/coverage/index.html"
  )
  mkdir -p "${WORKSPACE_DIR}/docs/coverage"
  ( cd "${BUILD_DIR}" && coverage_run_gcovr "${WORKSPACE_DIR}" )
else
  # The profiles are produced by ci-build-and-test.sh's ctest and fuzz runs -
  # one file per process, see LLVM_PROFILE_FILE there - so this only merges and
  # reports them; no coverage_llvm_generate_profile here.
  [[ -d "${PROFRAW_DIR}" ]] \
    || die "No profile directory at '${PROFRAW_DIR}'. ci-build-and-test.sh --compiler clang creates it; run that first, with the same --build-dir/--profraw-dir."
  mapfile -t PROFRAWS < <(find "${PROFRAW_DIR}" -maxdepth 1 -type f -name '*.profraw' | LC_ALL=C sort)
  if [[ ${#PROFRAWS[@]} -eq 0 ]]; then
    die "No .profraw under '${PROFRAW_DIR}': the test run wrote no coverage profile. Is myproject_ENABLE_COVERAGE ON in the preset that configured '${BUILD_DIR}' (linux-debug-clang sets it)?"
  fi
  [[ -f "${BUILD_DIR}/${COVERAGE_OBJECT}" ]] \
    || die "Coverage object '${BUILD_DIR}/${COVERAGE_OBJECT}' not found - the instrumented build did not produce the library."

  # The hub's coverage_llvm_report calls llvm-profdata and llvm-cov by bare name,
  # and the image's PATH copies are LLVM 21, which refuses clang 23's raw profile
  # format 11 (ci-common.sh, compiler_llvm_tool). Nothing else runs after this,
  # so the swap need not be scoped.
  use_compiler_llvm_tools "${BUILD_DIR}" llvm-profdata llvm-cov
  require_tools llvm-profdata llvm-cov

  # coverage_llvm_report takes ONE profile path. llvm-profdata merge accepts an
  # indexed profile as input as readily as a raw one, so every raw profile of the
  # run is merged into one indexed file first and that file is what the hub gets.
  MERGED_PROFILE="profraw-merged.profdata"
  info "Merging ${#PROFRAWS[@]} raw profile(s) from ${PROFRAW_DIR}"
  llvm-profdata merge -sparse "${PROFRAWS[@]}" -o "${BUILD_DIR}/${MERGED_PROFILE}"

  COVERAGE_LLVM_HTML_DIR="${WORKSPACE_DIR}/docs/coverage"
  ( cd "${BUILD_DIR}" && coverage_llvm_report \
      "${COVERAGE_OBJECT}" \
      "${MERGED_PROFILE}" \
      "coverage.profdata" \
      "${COVERAGE_JSON}" )
fi

info "Coverage report generated successfully"
