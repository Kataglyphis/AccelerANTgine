#!/usr/bin/env bash
set -euo pipefail

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
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "${COMPILER}" == "gcc" ]]; then
  (cd "${BUILD_DIR}" && gcovr --html-details "${WORKSPACE_DIR}/docs/coverage/index.html" -r .)
else
  (
    cd "${BUILD_DIR}" && \
      llvm-profdata merge -sparse Test/compile/default.profraw -o compileTestSuite.profdata && \
      llvm-cov report ./compileTestSuite -instr-profile=compileTestSuite.profdata && \
      llvm-cov export ./compileTestSuite -format=text -instr-profile=compileTestSuite.profdata > "${COVERAGE_JSON}" && \
      llvm-cov show ./compileTestSuite -instr-profile=compileTestSuite.profdata -format=html -output-dir "${WORKSPACE_DIR}/docs/coverage"
  )
fi
