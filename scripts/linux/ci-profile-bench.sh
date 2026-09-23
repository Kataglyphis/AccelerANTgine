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
# The window the workload still runs for when perf cannot (see perf_probe).
SMOKE_SECONDS="10"
# Where this script's own signalling server listens (see start_signalling_server).
SIGNALLING_PORT="18443"
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
# synthetic source until told to stop - as long as a signalling server answers,
# which start_signalling_server provides.
PROFILE_ARGS="--webrtc --source test"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --perf-timeout-seconds) PERF_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --smoke-seconds) SMOKE_SECONDS="${2:-}"; shift 2 ;;
    --signalling-port) SIGNALLING_PORT="${2:-}"; shift 2 ;;
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

# The workload is a WebRTC producer and needs a signalling server to stream. With
# none on its URI (default ws://127.0.0.1:8443) webrtcsink's signaller gets
# "Connection refused", the state turns Error, and the CLI's loop
# (Src/cli_main.cpp:250-258) breaks and returns 0 about 200 ms in - so with a
# real perf the lane died "exited cleanly before the window closed". Unless
# --profile-args names its own --server, this starts the image's
# gst-webrtc-signalling-server on 127.0.0.1:${SIGNALLING_PORT} and points the
# CLI at it; not 8443, where a dev box's own producer listens. AGENTS.md sec. 4.
SIGNALLING_PID=""
WORKLOAD_ARGS=("${PROFILE_ARGS_ARR[@]}")

workload_needs_signalling_server() {
  local arg webrtc=1
  for arg in "${PROFILE_ARGS_ARR[@]}"; do
    case "${arg}" in
      --server | --server=* | -server | -server=*) return 1 ;;
      --webrtc | --webrtc=true | -webrtc | -webrtc=true) webrtc=0 ;;
    esac
  done
  return "${webrtc}"
}

start_signalling_server() {
  workload_needs_signalling_server || return 0
  command -v gst-webrtc-signalling-server >/dev/null 2>&1 \
    || die "The workload needs a WebRTC signalling server and there is no gst-webrtc-signalling-server on PATH (gst-plugins-rs; the CI image has it in /opt/gstreamer/bin). Install it, or name a running server with --profile-args '... --server ws://HOST:PORT'."
  local log="${WORKSPACE_DIR}/${LOGS_DIR}/signalling-server.log" attempt
  gst-webrtc-signalling-server --host 127.0.0.1 --port "${SIGNALLING_PORT}" >"${log}" 2>&1 &
  SIGNALLING_PID=$!
  trap stop_signalling_server EXIT
  for ((attempt = 0; attempt < 50; attempt++)); do
    sleep 0.2
    kill -0 "${SIGNALLING_PID}" 2>/dev/null \
      || die "gst-webrtc-signalling-server exited before it listened on 127.0.0.1:${SIGNALLING_PORT} (port taken? --signalling-port picks another): $(tail -n 3 "${log}" | tr '\n' ' ')"
    if (exec 3<>"/dev/tcp/127.0.0.1/${SIGNALLING_PORT}") 2>/dev/null; then
      WORKLOAD_ARGS+=("--server=ws://127.0.0.1:${SIGNALLING_PORT}")
      info "signalling server for the workload: ws://127.0.0.1:${SIGNALLING_PORT} (log: ${log})"
      return 0
    fi
  done
  die "gst-webrtc-signalling-server did not listen on 127.0.0.1:${SIGNALLING_PORT} within 10 s: $(tail -n 3 "${log}" | tr '\n' ' ')"
}

stop_signalling_server() {
  [[ -n "${SIGNALLING_PID}" ]] || return 0
  kill "${SIGNALLING_PID}" 2>/dev/null || true
  wait "${SIGNALLING_PID}" 2>/dev/null || true
  SIGNALLING_PID=""
  trap - EXIT
}

# run_workload <what> <window-seconds> [recorder argv...] - the workload under
# `timeout`, behind the recorder when one is given. Exit 124 is timeout's own
# and the EXPECTED end: the CLI streams until stopped, perf finalizes perf.data
# on the TERM, and the CLI's SIGTERM handler (Src/cli_main.cpp:245-246) exits
# cleanly, which lets gperftools dump CPUPROFILE. An early exit 0 means the
# workload bailed out (bad flag, version-print, no signalling server) and only
# startup was measured; any other exit is a failure. This used to warn on ANY
# non-zero exit, so a lane that recorded nothing still went green.
run_workload() {
  local what="$1" window="$2" status=0
  shift 2
  start_signalling_server
  (
    cd "${BUILD_DIR}" && timeout "${window}" \
      "$@" env CPUPROFILE="${PROFILE_OUTPUT}" "./${PROFILE_BINARY}" "${WORKLOAD_ARGS[@]}"
  ) || status=$?
  stop_signalling_server

  if [[ "${status}" -eq 124 ]]; then
    info "${what} window closed by the configured ${window}s timeout (the intended bound)"
  elif [[ "${status}" -eq 0 ]]; then
    die "profiled workload exited cleanly before the ${window}s window closed - under '${PROFILE_ARGS}' the CLI streams until stopped, so an early exit 0 means nothing was profiled"
  else
    die "${what} failed with exit code ${status}"
  fi
}

perf_probe
if [[ -z "${PERF_SKIP_REASON}" ]]; then
  run_workload "perf record" "${PERF_TIMEOUT_SECONDS}" perf record "${PERF_RECORD_ARGS[@]}" --
  info "perf data: ${BUILD_DIR}/perf.data"
else
  warn "perf record SKIPPED - this host cannot run perf: ${PERF_SKIP_REASON}"
  warn "No perf.data is written. perf needs the 'perf' binary (Ubuntu 26.04: package linux-perf) and permission to open perf events (CAP_PERFMON or --privileged in a container, or a low enough kernel.perf_event_paranoid). The workload still runs for ${SMOKE_SECONDS}s without a recorder, so one that stops streaming early fails here either way."
  run_workload "workload (no recorder)" "${SMOKE_SECONDS}"
fi

if [[ -s "${PROFILE_OUTPUT}" ]]; then
  info "gperftools CPU profile: ${PROFILE_OUTPUT}"
else
  # Named expected case, not an error: ProjectOptions.cmake links -lprofiler
  # only when find_library(PROFILER_LIB profiler) succeeds; without it the
  # build falls back to -pg and CPUPROFILE is inert.
  info "no gperftools profile at ${PROFILE_OUTPUT} (libprofiler not linked; ProjectOptions.cmake fell back to -pg)"
fi

(cd "${BUILD_DIR}" && ./perfTestSuite --benchmark_out=results.json --benchmark_out_format=json)
