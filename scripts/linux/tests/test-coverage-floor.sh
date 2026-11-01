#!/usr/bin/env bash
# Runs ci-coverage.sh over stub gcovr/llvm-cov summaries at and below each floor; real profiles are not read.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
checker="${root}/scripts/linux/check-coverage-floor.py"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# Stubs write the summary for COVERED_LINES/1000 lines and COVERED_BRANCHES/1000 branches.
mkdir -p "${work}/bin"
cat > "${work}/bin/gcovr" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --json-summary ]]; then
    printf '{"line_total": 1000, "line_covered": %s, "branch_total": 1000, "branch_covered": %s}\n' \
      "${COVERED_LINES}" "${COVERED_BRANCHES}" > "$2"
  fi
  shift
done
SH
cat > "${work}/bin/llvm-cov" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == export ]]; then
  printf '{"data": [{"totals": {"lines": {"count": 1000, "covered": %s}, "branches": {"count": 1000, "covered": %s}}}]}\n' \
    "${COVERED_LINES}" "${COVERED_BRANCHES}"
fi
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/bin/llvm-profdata"
chmod +x "${work}/bin/"*

lane() {
  local compiler="$1" lines="$2" branches="$3" leg="${work}/leg-$1-$2-$3"
  mkdir -p "${leg}/build/profraw" "${leg}/build/lib"
  : > "${leg}/build/profraw/1.profraw"
  : > "${leg}/build/lib/libAccelerANTgine.so"
  (cd "${leg}" && PATH="${work}/bin:${PATH}" COVERED_LINES="${lines}" COVERED_BRANCHES="${branches}" \
    ANTFRASTRUCTURE_DIR="${root}/third_party/ANTfrastructure" \
    bash "${root}/scripts/linux/ci-coverage.sh" --compiler "${compiler}" --build-dir build) >"${work}/out" 2>&1
}
expect() {
  local want="$1" what="$2" rc=0
  shift 2
  lane "$@" || rc=$?
  if { [[ "${want}" == pass ]] && [[ "${rc}" -ne 0 ]]; } || { [[ "${want}" == fail ]] && [[ "${rc}" -eq 0 ]]; }; then
    fail "${what}: exit ${rc}, expected ${want}"
    cat "${work}/out" >&2
  else
    echo "ok: ${what}"
  fi
}

expect pass 'GCC at 69 % lines / 50 % branches' gcc 690 500
expect fail 'GCC below 69 % lines' gcc 689 500
expect fail 'GCC below 50 % branches' gcc 690 499
expect pass 'clang at 83 % lines / 68 % branches' clang 830 680
expect fail 'clang below 83 % lines' clang 829 680
expect fail 'clang below 68 % branches' clang 830 679
lane gcc 700 500
[[ -s "${work}/leg-gcc-700-500/logs/coverage/coverage-summary.json" ]] || fail 'the GCC summary is not kept under logs/coverage'
lane clang 850 700
[[ -s "${work}/leg-clang-850-700/logs/coverage/coverage.json" ]] || fail 'the clang export is not kept under logs/coverage'
grep -q 'coverage floor: lines 85.00% (minimum 83%), branches 70.00% (minimum 68%)' "${work}/out" \
  || fail "the clang leg does not print its floor: $(grep 'coverage floor' "${work}/out")"

# Exit 2 marks an unreadable report, which must never grade as covered.
expect_unreadable() {
  local what="$1" body="$2" status=0
  printf '%s\n' "${body}" > "${work}/summary.json"
  python3 "${checker}" "${work}/summary.json" --min-lines 1 --min-branches 1 >/dev/null 2>&1 || status=$?
  if [[ "${status}" -ne 2 ]]; then fail "${what} must be unreadable (2), got ${status}"; fi
  return 0
}
expect_unreadable 'a report without branches' '{"line_total": 1000, "line_covered": 900, "branch_total": 0, "branch_covered": 0}'
expect_unreadable 'a malformed report' 'not json'

[[ "${failures}" -eq 0 ]] || { echo "${failures} coverage-floor case(s) failed" >&2; exit 1; }
echo 'coverage floors: all cases passed'
