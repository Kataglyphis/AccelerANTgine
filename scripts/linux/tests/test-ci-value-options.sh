#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../ci-common.sh
source "${repo_root}/scripts/linux/ci-common.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

check_options() {
    local lane="$1" pair name
    shift
    local -A expected=()
    while [[ "${1:-}" != :: ]]; do
        [[ "$#" -gt 0 ]] || fail "${lane}: expected-options delimiter missing"
        pair="$1"
        name="${pair%%=*}"
        expected["${name}"]="${pair#*=}"
        shift
    done
    shift
    for name in "${!expected[@]}"; do printf -v "${name}" '%s' "default-${name}"; done
    ci_parse_value_options "${lane}" "$@"
    for name in "${!expected[@]}"; do
        assert_equal "${!name}" "${expected[${name}]}" "${lane} ${name}"
    done
}

check_coverage() {
    check_options coverage \
        WORKSPACE_DIR='work space' COMPILER=gcc BUILD_DIR=build-next \
        COVERAGE_JSON=coverage-next.json PROFRAW_DIR=raw-next :: \
        --workspace-dir 'work space' --compiler clang --compiler gcc \
        --build-dir build-next --coverage-json coverage-next.json --profraw-dir raw-next
}

check_profile_bench() {
    check_options profile-bench \
        PERF_TIMEOUT_SECONDS=31 SMOKE_SECONDS=7 SIGNALLING_PORT=19443 BUILD_DIR='profile build' \
        COMPILER=gcc GCC_PROFILE_PRESET=gnu-next CLANG_PROFILE_PRESET=clang-next \
        PROFILE_BINARY='bin/profile runner' PROFILE_ARGS='--webrtc --source test' :: \
        --perf-timeout-seconds 31 --smoke-seconds 7 --signalling-port 19443 \
        --build-dir 'profile build' --compiler clang --compiler gcc \
        --gcc-profile-preset gnu-next --clang-profile-preset clang-next \
        --profile-binary 'bin/profile runner' --profile-args '--webrtc --source test'
}

check_python_bindings() {
    check_options python-bindings \
        WORKSPACE_DIR='wheel work' OUT_DIR='dist next' BUILD_ROOT='/tmp/wheel root' \
        PYTHON_VERSION=3.15 COMPILER=gcc :: \
        --workspace-dir 'wheel work' --out-dir 'dist next' --build-root '/tmp/wheel root' \
        --python-version 3.15 --compiler clang --compiler gcc
}

check_finalize() {
    check_options finalize WORKSPACE_DIR='final work' :: --workspace-dir 'final work'
}

check_options build-and-test \
    WORKSPACE_DIR='work space' COMPILER=gcc BUILD_DIR=build-next BUILD_TYPE=RelWithDebInfo \
    GCC_DEBUG_PRESET=gnu-next CLANG_DEBUG_PRESET=clang-next CLANG_TSAN_PRESET=tsan-next \
    TSAN_BUILD_DIR=tsan-build-next PROFRAW_DIR=raw-next :: \
    --workspace-dir 'work space' --compiler clang --compiler gcc --build-dir build-next \
    --build-type RelWithDebInfo --gcc-debug-preset gnu-next --clang-debug-preset clang-next \
    --clang-tsan-preset tsan-next --tsan-build-dir tsan-build-next --profraw-dir raw-next
check_coverage
check_options docs \
    WORKSPACE_DIR='docs work' COMPILER=gcc RUNNER=runner-next DOCS_OUT='site output' :: \
    --workspace-dir 'docs work' --compiler gcc --runner runner-next --docs-out 'site output'
check_options init \
    WORKSPACE_DIR=init-next COMPILER=gcc RUNNER=runner-next MATRIX_ARCH=arm64 :: \
    --workspace-dir init-next --compiler gcc --runner runner-next --arch arm64
check_profile_bench
check_python_bindings
check_finalize
check_options run-all \
    COMPILER=gcc RUNNER=runner-next MATRIX_ARCH=arm64 BUILD_TYPE=Release BUILD_DIR=build-next \
    BUILD_RELEASE_DIR=release-next GCC_DEBUG_PRESET=gnu-next CLANG_DEBUG_PRESET=clang-next \
    GCC_PROFILE_PRESET=gnu-profile-next CLANG_PROFILE_PRESET=clang-profile-next \
    CLANG_RELEASE_PRESET=clang-release-next COVERAGE_JSON=coverage-next.json DOCS_OUT=site-next \
    RELEASE_CALLGRIND=1 RELEASE_APPIMAGE=0 RELEASE_FLATPAK=0 \
    RELEASE_APPIMAGE_OUT_DIR='app image' RELEASE_FLATPAK_OUT_DIR='flat pak' :: \
    --compiler gcc --runner runner-next --arch arm64 --build-type Release --build-dir build-next \
    --build-release-dir release-next --gcc-debug-preset gnu-next --clang-debug-preset clang-next \
    --gcc-profile-preset gnu-profile-next --clang-profile-preset clang-profile-next \
    --clang-release-preset clang-release-next --coverage-json coverage-next.json \
    --docs-out site-next --release-callgrind 1 --release-appimage 0 --release-flatpak 0 \
    --release-appimage-out-dir 'app image' --release-flatpak-out-dir 'flat pak'

COMPILER=unchanged
ci_parse_value_options init
assert_equal "${COMPILER}" unchanged 'empty argv keeps defaults'
ci_parse_value_options docs --compiler --flag-shaped-value
assert_equal "${COMPILER}" --flag-shaped-value 'flag-shaped value stays one argument'
PROFILE_ARGS=unchanged
ci_parse_value_options profile-bench
assert_equal "${PROFILE_ARGS}" unchanged 'empty profile argv keeps defaults'
ci_parse_value_options profile-bench --profile-args --flag-shaped-value
assert_equal "${PROFILE_ARGS}" --flag-shaped-value 'profile flag-shaped value stays one argument'
RELEASE_APPIMAGE_OUT_DIR=old
ci_parse_value_options run-all --release-appimage-out-dir ''
assert_equal "${RELEASE_APPIMAGE_OUT_DIR}" '' 'explicit empty optional output stays empty'
WORKSPACE_DIR=old
ci_parse_value_options finalize --workspace-dir ''
assert_equal "${WORKSPACE_DIR}" '' 'explicit empty final workspace stays empty'

expect_failure() {
    local diagnostic="$1" result status
    shift
    if result="$("$@" 2>&1)"; then fail "accepted invalid arguments: $*"; else status=$?; fi
    assert_equal "${status}" 1 "invalid arguments: $*"
    [[ "${result}" == *"${diagnostic}"* ]] || fail "missing diagnostic '${diagnostic}': ${result}"
}

for lane in build-and-test coverage docs init profile-bench python-bindings finalize run-all; do
    expect_failure 'Unknown argument: --wrong' ci_parse_value_options "${lane}" --wrong
    expect_failure 'Unknown argument: --' ci_parse_value_options "${lane}" --
done
expect_failure 'Unknown argument: --runner' ci_parse_value_options coverage --runner runner-next
for entry in build-and-test:--workspace-dir coverage:--coverage-json docs:--docs-out init:--arch profile-bench:--profile-args python-bindings:--build-root finalize:--workspace-dir run-all:--release-flatpak-out-dir; do
    lane="${entry%%:*}"
    flag="${entry#*:}"
    expect_failure "${flag} expects a value" ci_parse_value_options "${lane}" "${flag}"
done

for entry in build-and-test:ci-build-and-test.sh coverage:ci-coverage.sh docs:ci-docs.sh init:ci-init.sh profile-bench:ci-profile-bench.sh python-bindings:ci-python-bindings.sh finalize:ci-finalize.sh run-all:ci-run-all.sh; do
    lane="${entry%%:*}"
    file="${entry#*:}"
    needle='ci_parse_value_options '"${lane}"' "$@"'
    [[ "$(<"${repo_root}/scripts/linux/${file}")" == *"${needle}"* ]] || fail "${file} bypasses the shared parser"
done

# A missing map entry must fail the same complete mode check that passes above.
original="$(declare -f ci_parse_value_options)"
assert_mutant_rejected() {
    local label="$1" edit="$2" check="$3" mutant
    mutant="$(printf '%s\n' "${original}" | sed "${edit}")"
    [[ "${mutant}" != "${original}" ]] || fail "${label} mutant did not change the parser"
    if ( eval "${mutant}"; "${check}" >/dev/null 2>&1 ); then fail "${label} mutant escaped the test"; fi
}

assert_mutant_rejected coverage-map 's/\[--coverage-json\]=COVERAGE_JSON//g' check_coverage
assert_mutant_rejected profile-map 's/\[--profile-args\]=PROFILE_ARGS//g' check_profile_bench
assert_mutant_rejected Python-map 's/\[--build-root\]=BUILD_ROOT//g' check_python_bindings
assert_mutant_rejected finalize-map '/finalize)/,/;;/ s/\[--workspace-dir\]=WORKSPACE_DIR//' check_finalize

printf 'ci value options: eight modes, caller wiring and broken-map mutants OK\n'
