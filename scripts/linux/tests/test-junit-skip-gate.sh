#!/usr/bin/env bash
# Feeds fixture JUnit reports to the skip gate and checks each leg's report list; it runs no ctest or pytest.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="${root}/scripts/linux/check-junit-skips.py"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
expect() {
  local want="$1" what="$2" rc=0
  shift 2
  python3 "${gate}" "$@" >"${work}/out" 2>&1 || rc=$?
  if [[ "${rc}" -ne "${want}" ]]; then
    fail "${what}: exit ${rc}, expected ${want}"
    cat "${work}/out" >&2
  else
    echo "ok: ${what}"
  fi
}

passed='<testsuite name="ctest" tests="2"><testcase name="A.Passes" classname="A" status="run"/><testcase name="A.Also" classname="A" status="run"/></testsuite>'
printf '%s\n' "${passed}" > "${work}/ctest.xml"
printf '%s\n' '<testsuite name="ctest"><testcase name="T.Races" classname="T" status="run"><skipped message="[  SKIPPED ] under TSan"/></testcase></testsuite>' > "${work}/tsan-skip.xml"
printf '%s\n' '<testsuite name="ctest"><testcase name="T.Off" classname="T" status="notrun"/></testsuite>' > "${work}/notrun.xml"
printf '%s\n' '<testsuites><testsuite name="pytest"><testcase classname="test_threading" name="test_gil"><skipped type="pytest.skip" message="not free-threaded"/></testcase></testsuite></testsuites>' > "${work}/pytest-skip.xml"
printf '%s\n' '<testsuites><testsuite name="pytest"><testcase classname="test_bindings" name="test_ok"/></testsuite></testsuites>' > "${work}/pytest.xml"
printf '%s\n' '<testsuite name="ctest" tests="0"></testsuite>' > "${work}/empty.xml"
printf '%s\n' '<testsuite name="ctest"><testcase name="broken"' > "${work}/malformed.xml"

expect 0 'clean ctest and pytest reports pass' "${work}/ctest.xml" "${work}/pytest.xml"
expect 1 'a GTEST_SKIP in the TSan report fails' "${work}/ctest.xml" "${work}/tsan-skip.xml" "${work}/pytest.xml"
expect 1 'a not-run ctest case fails' "${work}/ctest.xml" "${work}/notrun.xml"
expect 1 'a pytest skip fails' "${work}/pytest-skip.xml"
expect 1 'a missing report fails' "${work}/ctest.xml" "${work}/absent.xml"
expect 1 'a report without testcases fails' "${work}/empty.xml"
expect 1 'a malformed report fails' "${work}/malformed.xml"

python3 "${gate}" "${work}/ctest.xml" "${work}/tsan-skip.xml" >"${work}/out" 2>&1 || true
grep -q 'skipped: .*tsan-skip.xml: T.T.Races' "${work}/out" || fail 'the skipped testcase is not named'
python3 "${gate}" "${work}/ctest.xml" "${work}/pytest.xml" >"${work}/out" 2>&1
grep -q '^junit skip gate: 2 report(s), 3 testcase(s), 0 skipped$' "${work}/out" || fail "wrong summary: $(cat "${work}/out")"

# The leg's list, read the way ci-run-all.sh reads it.
lists="$(cd "${root}" && bash -c 'source scripts/linux/ci-common.sh >/dev/null 2>&1; ci_junit_reports clang; echo ---; ci_junit_reports gcc')"
clang_list="${lists%%---*}"
gcc_list="${lists##*---}"
for report in docs/test_results.xml docs/test_results_tsan.xml logs/python-gil.xml logs/python-free-threaded.xml; do
  grep -qxF "${report}" <<< "${clang_list}" || fail "the clang leg does not gate ${report}"
done
[[ "$(grep -c . <<< "${gcc_list}")" -eq 1 ]] && grep -qxF docs/test_results.xml <<< "${gcc_list}" \
  || fail "the GCC leg must gate exactly its ctest report, got: ${gcc_list}"
grep -q 'check-junit-skips.py "${JUNIT_REPORTS\[@\]}"' "${root}/scripts/linux/ci-run-all.sh" \
  || fail 'ci-run-all.sh no longer gates every report of the leg'

[[ "${failures}" -eq 0 ]] || { echo "${failures} skip-gate case(s) failed" >&2; exit 1; }
echo 'JUnit skip gate: all cases passed'
