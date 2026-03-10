#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci_common.sh"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
COVERAGE_JSON="coverage.json"
LLVM_COV_IGNORE_REGEX=".*/(ExternalLib|build[^/]*/_deps|_deps|Test|tests|usr/include|usr/lib)/.*"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --coverage-json) COVERAGE_JSON="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "${COMPILER}" == "gcc" ]]; then
  info "Generating coverage report with gcovr (GCC)"
  (
    cd "${BUILD_DIR}" && \
      gcovr \
        --config "${WORKSPACE_DIR}/gcovr.cfg" \
        --root "${WORKSPACE_DIR}" \
        --filter "${WORKSPACE_DIR}/Src/.*" \
        --html-details "${WORKSPACE_DIR}/docs/coverage/index.html"
  )
else
  info "Generating coverage report with llvm-cov (Clang)"
  (
    cd "${BUILD_DIR}" && \
      llvm-profdata merge -sparse Test/compile/default.profraw -o compileTestSuite.profdata && \
      llvm-cov report ./compileTestSuite -instr-profile=compileTestSuite.profdata -ignore-filename-regex="${LLVM_COV_IGNORE_REGEX}" && \
      llvm-cov export ./compileTestSuite -format=text -instr-profile=compileTestSuite.profdata -ignore-filename-regex="${LLVM_COV_IGNORE_REGEX}" > "${COVERAGE_JSON}" && \
      llvm-cov show ./compileTestSuite -instr-profile=compileTestSuite.profdata -ignore-filename-regex="${LLVM_COV_IGNORE_REGEX}" -format=html -output-dir "${WORKSPACE_DIR}/docs/coverage"
  )
fi

info "Coverage report generated successfully"
