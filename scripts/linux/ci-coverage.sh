#!/usr/bin/env bash
# ci-coverage.sh - project wrapper around ContainerHub's generic coverage driver
# (linux/scripts/lib/coverage.sh). Both backends - gcovr for GCC, llvm-cov for
# Clang - previously lived here as hand-written pipelines; only this project's
# report paths, filters and the name of the instrumented suite remain.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

COVERAGE_LIB="${_SCRIPT_DIR}/../../ExternalLib/Kataglyphis-ContainerHub/linux/scripts/lib/coverage.sh"
if [[ ! -f "${COVERAGE_LIB}" ]]; then
  die "Shared coverage library not found at '${COVERAGE_LIB}'. Initialize the Kataglyphis-ContainerHub submodule first."
fi
# shellcheck disable=SC1091
source "${COVERAGE_LIB}"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
COVERAGE_JSON="coverage.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --coverage-json) COVERAGE_JSON="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Project-specific: what to leave out of the report. Dependencies, generated
# _deps trees and the test code itself are not the thing under measurement.
COVERAGE_LLVM_IGNORE_REGEX=(".*/(ExternalLib|build[^/]*/_deps|_deps|Test|tests|usr/include|usr/lib)/.*")

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
  # The profraw is produced by the compile suite during the test run, so this
  # only merges/reports it - no coverage_llvm_generate_profile here.
  COVERAGE_LLVM_HTML_DIR="${WORKSPACE_DIR}/docs/coverage"
  ( cd "${BUILD_DIR}" && coverage_llvm_report \
      "./compileTestSuite" \
      "Test/compile/default.profraw" \
      "compileTestSuite.profdata" \
      "${COVERAGE_JSON}" )
fi

info "Coverage report generated successfully"
