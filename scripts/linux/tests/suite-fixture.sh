#!/usr/bin/env bash
# Shared root, scratch directory and failure accounting for the Bash suites; it asserts nothing by itself.

export SUITE_ROOT
SUITE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
failures=0

# The EXIT trap removes SUITE_WORK however the suite ends.
SUITE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/accelerant-suite.XXXXXXXX")
trap 'rm -rf -- "${SUITE_WORK}"' EXIT

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# Usage: suite_expect pass|fail|EXIT_CODE WHAT COMMAND...; SUITE_OUTPUT_LINES bounds the printed "${SUITE_WORK}/out".
suite_expect() {
  local want=$1 what=$2 rc=0 matched=1
  shift 2
  "$@" || rc=$?
  case "${want}" in
    pass) [[ "${rc}" -eq 0 ]] || matched=0 ;;
    fail) [[ "${rc}" -ne 0 ]] || matched=0 ;;
    *) [[ "${rc}" -eq "${want}" ]] || matched=0 ;;
  esac
  if [[ "${matched}" -eq 1 ]]; then echo "ok: ${what}"; return 0; fi
  fail "${what}: exit ${rc}, expected ${want}"
  if [[ -n "${SUITE_OUTPUT_LINES:-}" ]]; then tail -n "${SUITE_OUTPUT_LINES}" "${SUITE_WORK}/out" >&2; else cat "${SUITE_WORK}/out" >&2; fi
}

suite_failure_count() { printf '%s\n' "${failures}"; }

# Usage: suite_finish NAME; the suite's verdict after every case has run.
suite_finish() {
  [[ "${failures}" -eq 0 ]] || { echo "${failures} $1 case(s) failed" >&2; exit 1; }
}

# Usage: suite_refuses MESSAGE COMMAND...; a command that succeeds is the failure.
suite_refuses() {
  local message=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "${message}" >&2; exit 1; fi
}

# Usage: suite_refuses_logged MESSAGE PATTERN LOG COMMAND...; the refusal must also name PATTERN in LOG.
suite_refuses_logged() {
  local message=$1 pattern=$2 log=$3
  shift 3
  if "$@" >"${log}" 2>&1; then echo "${message}" >&2; exit 1; fi
  grep -Fq "${pattern}" "${log}" || { cat "${log}" >&2; exit 1; }
}

# Usage: workspace=$(suite_new_workspace); paths with spaces prove the driver under test quotes them.
suite_new_workspace() {
  local workspace="${SUITE_WORK}/project with spaces"
  mkdir -p "${workspace}/scripts/linux" "${workspace}/bin"
  printf '%s\n' "${workspace}"
}

# Usage: suite_log_stubs; prints the info and die a stubbed ci-common.sh or common.sh starts with.
suite_log_stubs() {
  cat <<'STUB'
info() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
STUB
}
