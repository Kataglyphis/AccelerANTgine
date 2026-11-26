#!/usr/bin/env bash
# Runs ci-run-all.sh over stub stage scripts: a part whose inner step fails must fail, not report ok.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
lane="${work}/lane"
mkdir -p "${lane}/scripts/linux/lib"
cp "${root}/scripts/linux/ci-run-all.sh" "${root}/scripts/linux/ci-common.sh" "${lane}/scripts/linux/"
cp "${root}/scripts/linux/lib/antfrastructure.sh" "${root}/scripts/linux/lib/renovate-git-mode.sh" "${lane}/scripts/linux/lib/"
export ANTFRASTRUCTURE_DIR="${root}/third_party/ANTfrastructure"

for stage in ci-init ci-build-and-test ci-docs ci-finalize; do
  printf '#!/usr/bin/env bash\necho "ran %s" >> "${STUB_LOG}"\n[[ "${STUB_FAIL:-}" != %s ]]\n' "${stage}" "${stage}" \
    > "${lane}/scripts/linux/${stage}.sh"
done
export STUB_LOG="${work}/stages"

# arm64 keeps the warning census, a hub script reading a real build log, out of the part.
run_part() {
  : > "${STUB_LOG}"
  (cd "${lane}" && rm -rf build && mkdir build && STUB_FAIL="$1" bash scripts/linux/ci-run-all.sh --part "$2" --compiler gcc --arch arm64) \
    >"${work}/out" 2>&1
}
expect() { suite_expect "$1" "$2" run_part "${@:3}"; }

expect 0 'a build-test part whose steps pass is ok' '' build-test
[[ -f "${lane}/build/.lane-built" ]] || fail 'a green build-test leaves no .lane-built marker'
expect 1 'a failed build and test step fails build-test' ci-build-and-test build-test
[[ ! -e "${lane}/build/.lane-built" ]] || fail 'a failed build still marks the lane built'
expect 1 'a failed init fails build-test before the build' ci-init build-test
grep -qx 'ran ci-build-and-test' "${STUB_LOG}" && fail 'the build ran after a failed init'
expect 1 'a failed docs build fails the docs part' ci-docs docs
expect 0 'a docs part whose steps pass is ok' '' docs

suite_finish ci-run-all-parts
echo 'ci-run-all parts: all cases passed'
