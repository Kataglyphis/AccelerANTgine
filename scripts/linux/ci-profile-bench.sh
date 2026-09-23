#!/usr/bin/env bash
# ci-profile-bench.sh - project wrapper around ANTfrastructure's generic CMake build
# driver (linux/scripts/lib/cmake-build.sh) for the profiling/benchmark lane.
#
# The jobs computation and the configure+build pair this file used to duplicate
# from ci-build-and-test.sh now come from cmake_build_jobs / cmake_build_run, and
# the clean rebuild is cmake_build_run's --clean-build-dir instead of a local
# `rm -rf`. cmake_build_prepare_env comes with them: CCACHE_SECONDARY_STORAGE
# sanity plus the writable CARGO_HOME/SCCACHE_DIR/CCACHE_DIR fallbacks that this
# repo had no equivalent of (see ci-build-and-test.sh for the incidents).
#
# What stays here is the profiling itself: perf record over the CLI binary and
# the Google Benchmark suite.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source, not a "${_SCRIPT_DIR}/../../third_party/ANTfrastructure/..."
# literal: it resolves under ANTFRASTRUCTURE_DIR (which the literal ignored, so the
# bootstrap's environment override did nothing) and fails naming the probed path
# and the fix. In scope because ci-common.sh sources lib/antfrastructure.sh.
antfrastructure_source linux/scripts/lib/cmake-build.sh

PERF_TIMEOUT_SECONDS="180"
BUILD_DIR="build"
COMPILER="clang"
GCC_PROFILE_PRESET="linux-profile-GNU"
CLANG_PROFILE_PRESET="linux-profile-clang"
LOGS_DIR="logs"
PROFILE_OUTPUT=""

# The binary perf profiles. Src/CMakeLists.txt builds the CLI as
# ${PROJECT_NAME}_cli with OUTPUT_NAME ${PROJECT_NAME} into ${CMAKE_BINARY_DIR}/bin,
# and PROJECT_NAME is AccelerANTgine since the rename (CMakeLists.txt:5). This
# line still said "./KataglyphisCppProject" - the pre-rename name, and in the
# wrong directory on top of it, so perf never had anything to record.
PROFILE_BINARY="bin/AccelerANTgine"

# The workload under the profiler. Without --webrtc the CLI prints its version
# and exits 0 (Src/cli_main.cpp:168-175), so a bare invocation profiles process
# startup and nothing else. The usage block in cli_main.cpp documents
# `--webrtc --source test` as the headless no-camera path; it streams the
# synthetic source until told to stop, which gives perf a real window.
PROFILE_ARGS="--webrtc --source test"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --perf-timeout-seconds) PERF_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --gcc-profile-preset) GCC_PROFILE_PRESET="${2:-}"; shift 2 ;;
    --clang-profile-preset) CLANG_PROFILE_PRESET="${2:-}"; shift 2 ;;
    --profile-binary) PROFILE_BINARY="${2:-}"; shift 2 ;;
    --profile-args) PROFILE_ARGS="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Deliberate word-splitting: --profile-args is a whole argv tail for the
# profiled binary, not a single token.
read -r -a PROFILE_ARGS_ARR <<<"${PROFILE_ARGS}"

WORKSPACE_DIR="$(pwd)"
PROFILE_OUTPUT="${WORKSPACE_DIR}/${LOGS_DIR}/profile.prof"
mkdir -p "${WORKSPACE_DIR}/${LOGS_DIR}"

if [[ "${COMPILER}" == "gcc" ]]; then
  PRESET="${GCC_PROFILE_PRESET}"
else
  PRESET="${CLANG_PROFILE_PRESET}"
fi

CMAKE_BUILD_SAFE_DIRECTORY="${WORKSPACE_DIR}"

info "Using profiling preset: ${PRESET}"
# --mb-per-job 2000: the per-job RAM cap the pre-library jobs computation used
# (parallelism.sh generic profile); cmake-build.sh's 4000 default would cut the
# job count on memory-capped runners.
cmake_build_main --preset "${PRESET}" --build-dir "${BUILD_DIR}" --clean-build-dir true --mb-per-job 2000

if [[ ! -x "${BUILD_DIR}/${PROFILE_BINARY}" ]]; then
  die "Profiling target '${BUILD_DIR}/${PROFILE_BINARY}' is missing or not executable after building preset '${PRESET}'."
fi

# How perf records, shared by the probe and the real run so that a passing probe
# vouches for exactly the options the real run uses (--call-graph dwarf needs a
# perf built with DWARF unwinding, not just any perf).
PERF_RECORD_ARGS=(-F 99 --call-graph dwarf)

# Can this host run perf at all? Sets PERF_SKIP_REASON when it cannot. The CI
# image cannot: Ubuntu 26.04's linux-tools-common no longer ships /usr/bin/perf
# (it moved to linux-perf, which the image does not install), and the bare
# `timeout ... perf record` died with exit 127, "timeout: failed to execute
# process" (run 35921977662). Such a host - or one whose perf_event_paranoid or
# seccomp forbids perf_event_open - gets a WARN naming why. The probe records
# `true` with the real options, so once it passes every exit of the real run but
# 124 stays fatal. Detail: AGENTS.md section 4.
perf_probe() {
  PERF_SKIP_REASON=""
  if ! command -v perf >/dev/null 2>&1; then
    PERF_SKIP_REASON="no 'perf' on PATH"
    return 0
  fi
  local probe_dir probe_out probe_status=0
  probe_dir="$(mktemp -d)"
  probe_out="$(timeout 60 perf record "${PERF_RECORD_ARGS[@]}" -o "${probe_dir}/probe.data" -- true 2>&1)" \
    || probe_status=$?
  rm -rf "${probe_dir}"
  if [[ "${probe_status}" -ne 0 ]]; then
    PERF_SKIP_REASON="'perf record ${PERF_RECORD_ARGS[*]} -- true' exited ${probe_status}: ${probe_out//$'\n'/ | }"
  fi
}

# Exit 124 is `timeout` reporting ITS OWN configured timeout, and here it is the
# EXPECTED end of a good run: under ${PROFILE_ARGS} the CLI streams the synthetic
# test source until told to stop, so PERF_TIMEOUT_SECONDS is what closes the
# profile window. perf finalizes perf.data when timeout TERMs it, and the CLI's
# own SIGTERM handler (Src/cli_main.cpp:245-246) exits cleanly, which is what
# lets gperftools dump CPUPROFILE. Everything else is a real failure - perf
# refusing the real workload after the probe passed, or a binary that crashed or
# bailed out before the window closed. This block used to be wrapped in
# `set +e` and warn on ANY non-zero exit, so a lane that never recorded a single
# sample still went green.
run_perf_record() {
  local perf_exit=0
  (
    cd "${BUILD_DIR}" && timeout "${PERF_TIMEOUT_SECONDS}" \
      perf record "${PERF_RECORD_ARGS[@]}" -- \
      env CPUPROFILE="${PROFILE_OUTPUT}" "./${PROFILE_BINARY}" "${PROFILE_ARGS_ARR[@]}"
  ) || perf_exit=$?

  if [[ "${perf_exit}" -eq 124 ]]; then
    info "perf window closed by the configured ${PERF_TIMEOUT_SECONDS}s timeout (the intended bound)"
  elif [[ "${perf_exit}" -eq 0 ]]; then
    # A good run can ONLY end in 124: timeout exits 124 whenever it had to stop
    # the child, and under ${PROFILE_ARGS} the CLI streams until stopped. A clean
    # early exit therefore means the workload bailed out (bad flag, immediate
    # version-print-and-exit, missing source) and the profile measured startup.
    die "profiled workload exited cleanly before the ${PERF_TIMEOUT_SECONDS}s window closed - under '${PROFILE_ARGS}' the CLI streams until stopped, so an early exit 0 means nothing was profiled"
  else
    die "perf record failed with exit code ${perf_exit}"
  fi

  info "perf data: ${BUILD_DIR}/perf.data"
  if [[ -s "${PROFILE_OUTPUT}" ]]; then
    info "gperftools CPU profile: ${PROFILE_OUTPUT}"
  else
    # Named expected case, not an error: ProjectOptions.cmake links -lprofiler
    # only when find_library(PROFILER_LIB profiler) succeeds; without it the
    # build falls back to -pg and CPUPROFILE is inert.
    info "no gperftools profile at ${PROFILE_OUTPUT} (libprofiler not linked; ProjectOptions.cmake fell back to -pg)"
  fi
}

perf_probe
if [[ -z "${PERF_SKIP_REASON}" ]]; then
  run_perf_record
else
  warn "perf record SKIPPED - this host cannot run perf: ${PERF_SKIP_REASON}"
  warn "No perf.data is written and the profiled workload does not run; the benchmark suite below still does. perf needs the 'perf' binary (Ubuntu 26.04: package linux-perf) and permission to open perf events (CAP_PERFMON or --privileged in a container, or a low enough kernel.perf_event_paranoid)."
fi

(cd "${BUILD_DIR}" && ./perfTestSuite --benchmark_out=results.json --benchmark_out_format=json)
