#!/usr/bin/env bash
# ci-coverage.sh - this project's report paths and filters over ANTfrastructure's coverage.sh.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_path (via ci-common.sh) honours the ANTFRASTRUCTURE_DIR override; the directive lets shellcheck see the knobs read there.
# shellcheck source=third_party/ANTfrastructure/linux/scripts/lib/coverage.sh
source "$(antfrastructure_path linux/scripts/lib/coverage.sh)"

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
BUILD_DIR="build"
COVERAGE_JSON="coverage.json"
# Must match ci-build-and-test.sh; empty means <build-dir>/profraw there too.
PROFRAW_DIR=""

ci_parse_value_options coverage "$@"
PROFRAW_DIR="${PROFRAW_DIR:-${BUILD_DIR}/profraw}"

# Dependencies, _deps trees and the tests themselves are not under measurement.
COVERAGE_LLVM_IGNORE_REGEX=(".*/(third_party|build[^/]*/_deps|_deps|Test|tests|usr/include|usr/lib)/.*")

# llvm-cov reports only the object it is given, and Src/ lives in this library, not in the test suites.
COVERAGE_OBJECT="lib/libAccelerANTgine.so"

# gcovr and llvm-cov count lines and branches differently, so each compiler has its own floor.
COVERAGE_MIN_LINES_GCC=69
COVERAGE_MIN_BRANCHES_GCC=50
COVERAGE_MIN_LINES_CLANG=83
COVERAGE_MIN_BRANCHES_CLANG=68
# ci-profile-bench.sh wipes the build tree, so the summaries the lane uploads live here.
COVERAGE_REPORT_DIR="${WORKSPACE_DIR}/logs/coverage"
mkdir -p "${COVERAGE_REPORT_DIR}"

if [[ "${COMPILER}" == "gcc" ]]; then
  # The paths baked into .gcno are relative to the build directory, hence the cd.
  COVERAGE_SUMMARY="${COVERAGE_REPORT_DIR}/coverage-summary.json"
  COVERAGE_GCOVR_EXTRA_ARGS=(
    --config "${WORKSPACE_DIR}/gcovr.cfg"
    --filter "${WORKSPACE_DIR}/Src/.*"
    --html-details "${WORKSPACE_DIR}/docs/coverage/index.html"
    --json-summary "${COVERAGE_SUMMARY}"
  )
  mkdir -p "${WORKSPACE_DIR}/docs/coverage"
  ( cd "${BUILD_DIR}" && coverage_run_gcovr "${WORKSPACE_DIR}" )
  python3 "${_SCRIPT_DIR}/check-coverage-floor.py" "${COVERAGE_SUMMARY}" \
    --min-lines "${COVERAGE_MIN_LINES_GCC}" --min-branches "${COVERAGE_MIN_BRANCHES_GCC}" \
    || die "GCC coverage is below its floor (see the line above)."
else
  # ci-build-and-test.sh's runs wrote the profiles, so this only merges and reports them.
  [[ -d "${PROFRAW_DIR}" ]] \
    || die "No profile directory at '${PROFRAW_DIR}'. ci-build-and-test.sh --compiler clang creates it; run that first, with the same --build-dir/--profraw-dir."
  mapfile -t PROFRAWS < <(find "${PROFRAW_DIR}" -maxdepth 1 -type f -name '*.profraw' | LC_ALL=C sort)
  if [[ ${#PROFRAWS[@]} -eq 0 ]]; then
    die "No .profraw under '${PROFRAW_DIR}': the test run wrote no coverage profile. Is myproject_ENABLE_COVERAGE ON in the preset that configured '${BUILD_DIR}' (linux-debug-clang sets it)?"
  fi
  [[ -f "${BUILD_DIR}/${COVERAGE_OBJECT}" ]] \
    || die "Coverage object '${BUILD_DIR}/${COVERAGE_OBJECT}' not found - the instrumented build did not produce the library."

  # Must be clang's own LLVM pair: an older llvm-profdata refuses clang 23's raw profile format.
  require_tools llvm-profdata llvm-cov

  # coverage_llvm_report takes one profile, so every raw profile is merged into one indexed file first.
  MERGED_PROFILE="profraw-merged.profdata"
  info "Merging ${#PROFRAWS[@]} raw profile(s) from ${PROFRAW_DIR}"
  llvm-profdata merge -sparse "${PROFRAWS[@]}" -o "${BUILD_DIR}/${MERGED_PROFILE}"

  COVERAGE_LLVM_HTML_DIR="${WORKSPACE_DIR}/docs/coverage"
  ( cd "${BUILD_DIR}" && coverage_llvm_report \
      "${COVERAGE_OBJECT}" \
      "${MERGED_PROFILE}" \
      "coverage.profdata" \
      "${COVERAGE_JSON}" )
  cp "${BUILD_DIR}/${COVERAGE_JSON}" "${COVERAGE_REPORT_DIR}/coverage.json"
  python3 "${_SCRIPT_DIR}/check-coverage-floor.py" "${COVERAGE_REPORT_DIR}/coverage.json" \
    --min-lines "${COVERAGE_MIN_LINES_CLANG}" --min-branches "${COVERAGE_MIN_BRANCHES_CLANG}" \
    || die "clang coverage is below its floor (see the line above)."
fi

info "Coverage report generated successfully"
