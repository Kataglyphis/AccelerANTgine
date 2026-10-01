#!/usr/bin/env bash
# riscv64 lane: Debug cross build on the amd64 image, the commit/compile/fuzz suites run under QEMU. See AGENTS.md § The riscv64 lane
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

antfrastructure_source linux/scripts/lib/riscv64-cross.sh
antfrastructure_source linux/scripts/lib/cmake-build.sh
antfrastructure_source linux/scripts/lib/ctest-run.sh

WORKSPACE_DIR="$(pwd)"
BUILD_DIR="build-riscv64"
CMAKE_BUILD_SAFE_DIRECTORY="${WORKSPACE_DIR}"
CTEST_RUN_SAFE_DIRECTORY="${WORKSPACE_DIR}"

riscv64_cross_env
# No sanitizers, coverage or TSan: the cross clang has no riscv64 compiler-rt; the native lanes keep them.
cmake_build_main --preset linux-riscv64-cross --build-dir "${BUILD_DIR}" --mb-per-job 2000

(
  ctest_run_main \
    --build-dir "${BUILD_DIR}" \
    --build-type Debug \
    -- --output-junit "${WORKSPACE_DIR}/docs/test_results_riscv64.xml" --no-tests=error
)

FUZZ_TEST="${BUILD_DIR}/fuzzTestSuite"
[[ -x "${FUZZ_TEST}" ]] || die "Fuzz test binary '${FUZZ_TEST}' is missing; the riscv64 preset is Debug + Clang, which builds Test/fuzz."
"${FUZZ_TEST}"
