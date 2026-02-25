#!/usr/bin/env bash
set -euo pipefail

PERF_TIMEOUT_SECONDS="180"
BUILD_DIR="build"
COMPILER="clang"
GCC_PROFILE_PRESET="linux-profile-GNU"
CLANG_PROFILE_PRESET="linux-profile-clang"
LOGS_DIR="logs"
PROFILE_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --perf-timeout-seconds) PERF_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --gcc-profile-preset) GCC_PROFILE_PRESET="${2:-}"; shift 2 ;;
    --clang-profile-preset) CLANG_PROFILE_PRESET="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORKSPACE_DIR="$(pwd)"
PROFILE_OUTPUT="${WORKSPACE_DIR}/${LOGS_DIR}/profile.prof"
mkdir -p "${WORKSPACE_DIR}/${LOGS_DIR}"

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
(cd "${BUILD_DIR}" && timeout "${PERF_TIMEOUT_SECONDS}" perf record -F 99 --call-graph dwarf -- env CPUPROFILE="${PROFILE_OUTPUT}" ./KataglyphisCppProject)
PERF_EXIT=$?
set -e

if [[ "${PERF_EXIT}" -eq 124 ]]; then
  echo "perf record timed out after ${PERF_TIMEOUT_SECONDS}s, continuing"
elif [[ "${PERF_EXIT}" -ne 0 ]]; then
  echo "perf record exited with code ${PERF_EXIT}, continuing"
fi

echo "CPU profile output path: ${PROFILE_OUTPUT}"

(cd "${BUILD_DIR}" && ./perfTestSuite --benchmark_out=results.json --benchmark_out_format=json)
