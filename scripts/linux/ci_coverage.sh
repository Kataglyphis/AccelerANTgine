#!/usr/bin/env bash
set -euo pipefail

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
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "${COMPILER}" == "gcc" ]]; then
  (
    cd "${BUILD_DIR}" && \
      gcovr \
        --config "${WORKSPACE_DIR}/gcovr.cfg" \
        --root "${WORKSPACE_DIR}" \
        --filter "${WORKSPACE_DIR}/Src/.*" \
        --html-details "${WORKSPACE_DIR}/docs/coverage/index.html"
  )
else
  (
    cd "${BUILD_DIR}" && \
      llvm-profdata merge -sparse Test/compile/default.profraw -o compileTestSuite.profdata && \
      llvm-cov report ./compileTestSuite -instr-profile=compileTestSuite.profdata -ignore-filename-regex="${LLVM_COV_IGNORE_REGEX}" && \
      llvm-cov export ./compileTestSuite -format=text -instr-profile=compileTestSuite.profdata -ignore-filename-regex="${LLVM_COV_IGNORE_REGEX}" > "${COVERAGE_JSON}" && \
      llvm-cov show ./compileTestSuite -instr-profile=compileTestSuite.profdata -ignore-filename-regex="${LLVM_COV_IGNORE_REGEX}" -format=html -output-dir "${WORKSPACE_DIR}/docs/coverage"
  )
fi
