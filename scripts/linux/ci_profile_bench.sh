#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci_common.sh"

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
    *) die "Unknown argument: $1" ;;
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

# Use cgroup-aware parallelism for the build
JOBS="$(compute_jobs_with_mem_cap)"
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
info "Build parallelism: ${JOBS} jobs (cgroup + memory aware)"

info "Using profiling preset: ${PRESET}"
cmake -B "${BUILD_DIR}" --preset "${PRESET}"
cmake --build "${BUILD_DIR}" --preset "${PRESET}"

set +e
(cd "${BUILD_DIR}" && timeout "${PERF_TIMEOUT_SECONDS}" perf record -F 99 --call-graph dwarf -- env CPUPROFILE="${PROFILE_OUTPUT}" ./KataglyphisCppProject)
PERF_EXIT=$?
set -e

if [[ "${PERF_EXIT}" -eq 124 ]]; then
  warn "perf record timed out after ${PERF_TIMEOUT_SECONDS}s, continuing"
elif [[ "${PERF_EXIT}" -ne 0 ]]; then
  warn "perf record exited with code ${PERF_EXIT}, continuing"
fi

info "CPU profile output path: ${PROFILE_OUTPUT}"

(cd "${BUILD_DIR}" && ./perfTestSuite --benchmark_out=results.json --benchmark_out_format=json)
