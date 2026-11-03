#!/usr/bin/env bash
# Feeds fixture JUnit reports to the skip gate and checks each leg's report list; it runs no ctest or pytest.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
gate="${root}/scripts/linux/check-junit-skips.py"

run_gate() { python3 "${gate}" "$@" >"${work}/out" 2>&1; }
expect() { suite_expect "$1" "$2" run_gate "${@:3}"; }

passed='<testsuite name="ctest" tests="2"><testcase name="A.Passes" classname="A" status="run"/><testcase name="A.Also" classname="A" status="run"/></testsuite>'
printf '%s\n' "${passed}" > "${work}/ctest.xml"
printf '%s\n' '<testsuite name="ctest"><testcase name="T.Races" classname="T" status="run"><skipped message="[  SKIPPED ] under TSan"/></testcase></testsuite>' > "${work}/tsan-skip.xml"
printf '%s\n' '<testsuite name="ctest"><testcase name="T.Off" classname="T" status="notrun"/></testsuite>' > "${work}/notrun.xml"
printf '%s\n' '<testsuites><testsuite name="pytest"><testcase classname="test_threading" name="test_gil"><skipped type="pytest.skip" message="not free-threaded"/></testcase></testsuite></testsuites>' > "${work}/pytest-skip.xml"
printf '%s\n' '<testsuites><testsuite name="pytest"><testcase classname="test_bindings" name="test_ok"/></testsuite></testsuites>' > "${work}/pytest.xml"
printf '%s\n' '<testsuite name="ctest" tests="0"></testsuite>' > "${work}/empty.xml"
printf '%s\n' '<testsuite name="ctest"><testcase name="broken"' > "${work}/malformed.xml"

expect 0 'clean ctest and pytest reports pass' "${work}/ctest.xml" "${work}/pytest.xml"
expect 1 'a gtest skip in the TSan report fails' "${work}/ctest.xml" "${work}/tsan-skip.xml" "${work}/pytest.xml"
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
# Every report the ci-run-all.sh scripts write must be on the clang list, so a new suite cannot go unread.
while IFS= read -r written; do
  for label in gil free-threaded; do
    report="${written//\$\{label\}/${label}}"
    grep -qxF "${report}" <<< "${clang_list}" || fail "${report} is written but not gated"
  done
done < <(grep -ohE '(--junitxml=|--output-junit |ctest_with_junit "[^"]+" )"\$\{WORKSPACE_DIR\}/[^"]+"' "${root}"/scripts/linux/ci-build-and-test.sh "${root}"/scripts/linux/ci-python-bindings.sh \
  | sed -E 's#.*WORKSPACE_DIR\}/([^"]+)"#\1#' | sort -u)
grep -q 'check-junit-skips.py "${JUNIT_REPORTS\[@\]}"' "${root}/scripts/linux/ci-run-all.sh" \
  || fail 'ci-run-all.sh no longer gates every report of the leg'

suite_finish skip-gate
echo 'JUnit skip gate: all cases passed'
