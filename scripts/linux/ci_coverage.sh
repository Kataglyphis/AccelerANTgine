#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"

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
