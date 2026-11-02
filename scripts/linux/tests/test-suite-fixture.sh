#!/usr/bin/env bash
# Proves the shared suite helpers can report a failure; the suites prove their own cases.
set -euo pipefail
# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
: > "${SUITE_WORK}/out"
suite_expect pass 'pass matches' true
suite_expect fail 'fail matches' false
suite_expect 3 'a code matches' bash -c 'exit 3'
[[ "$(suite_failure_count)" -eq 0 ]] || { echo 'A matching verdict counted as a failure' >&2; exit 1; }
suite_expect pass 'pass mismatches' false 2>/dev/null
suite_expect fail 'fail mismatches' true 2>/dev/null
suite_expect 3 'a code mismatches' true 2>/dev/null
[[ "$(suite_failure_count)" -eq 3 ]] || { echo "Three mismatches counted $(suite_failure_count)" >&2; exit 1; }
if (suite_finish fixture) 2>/dev/null; then echo 'suite_finish passed a failed suite' >&2; exit 1; fi
if (suite_refuses 'refused' true) 2>/dev/null; then echo 'suite_refuses accepted a success' >&2; exit 1; fi
(suite_refuses 'unused' false)
if (suite_refuses_logged 'unused' 'absent' "${SUITE_WORK}/log" false) 2>/dev/null; then
  echo 'suite_refuses_logged accepted a refusal without its pattern' >&2; exit 1
fi
(suite_refuses_logged 'unused' 'named' "${SUITE_WORK}/log" bash -c 'echo named; exit 1')
workspace=$(suite_new_workspace)
[[ -d "${workspace}/scripts/linux" && -d "${workspace}/bin" && "${workspace}" == *' '* ]]
echo 'Suite fixture checks passed'
