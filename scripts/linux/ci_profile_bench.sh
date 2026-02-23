#!/usr/bin/env bash
set -euo pipefail

PERF_TIMEOUT_SECONDS="${PERF_TIMEOUT_SECONDS:-180}"

rm -rf "${BUILD_DIR}"

if [[ "${COMPILER}" == "gcc" ]]; then
  PRESET="${GCC_PROFILE_PRESET}"
else
  PRESET="${CLANG_PROFILE_PRESET}"
fi

echo "Using profiling preset: ${PRESET}"
cmake -B "${BUILD_DIR}" --preset "${PRESET}"
cmake --build "${BUILD_DIR}" --preset "${PRESET}"

set +e
(cd "${BUILD_DIR}" && timeout "${PERF_TIMEOUT_SECONDS}" perf record -F 99 --call-graph dwarf -- ./KataglyphisCppProject)
PERF_EXIT=$?
set -e

if [[ "${PERF_EXIT}" -eq 124 ]]; then
  echo "perf record timed out after ${PERF_TIMEOUT_SECONDS}s, continuing"
elif [[ "${PERF_EXIT}" -ne 0 ]]; then
  echo "perf record exited with code ${PERF_EXIT}, continuing"
fi

(cd "${BUILD_DIR}" && ./perfTestSuite --benchmark_out=results.json --benchmark_out_format=json)
