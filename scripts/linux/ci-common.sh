#!/usr/bin/env bash
# ci-common.sh - source after set -euo pipefail for ANTfrastructure's core library (info/die, arch_oci, compute_jobs, apt_install).

[ -n "${_CI_COMMON_SH_LOADED:-}" ] && return 0
_CI_COMMON_SH_LOADED=1

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ANTFRASTRUCTURE_DIR comes from lib/antfrastructure.sh, a verbatim copy of the upstream template.
# shellcheck disable=SC1091
source "${_CI_COMMON_DIR}/lib/antfrastructure.sh"

# No fallback: the ci-*.sh chain runs hub scripts next, so a missing hub stops here with the bootstrap's fix.
_ANTFRASTRUCTURE_CORE="$(antfrastructure_path linux/scripts/01-core)" || exit 1
# shellcheck disable=SC1091
source "${_ANTFRASTRUCTURE_CORE}/common.sh"
# shellcheck disable=SC1091
source "${_ANTFRASTRUCTURE_CORE}/modules.sh"
info "ANTfrastructure core library loaded from ${_ANTFRASTRUCTURE_CORE}"

antfrastructure_source linux/scripts/lib/cli-value-options.sh

ci_unknown_argument() { die "Unknown argument: $1"; }

# Every JUnit report one leg writes; the skip gate requires each, so a report that vanishes fails too.
ci_junit_reports() {
    printf '%s\n' docs/test_results.xml
    if [[ "$1" == "clang" ]]; then
        printf '%s\n' docs/test_results_tsan.xml logs/python-gil.xml logs/python-free-threaded.xml \
            logs/python-contract-gil.xml logs/python-contract-free-threaded.xml
    fi
}

ci_parse_value_options() {
    local _ci_lane="$1"
    shift
    local -A _ci_options=()
    case "${_ci_lane}" in
        build-and-test)
            _ci_options=(
                [--workspace-dir]=WORKSPACE_DIR [--compiler]=COMPILER [--build-dir]=BUILD_DIR
                [--build-type]=BUILD_TYPE [--gcc-debug-preset]=GCC_DEBUG_PRESET
                [--clang-debug-preset]=CLANG_DEBUG_PRESET [--clang-tsan-preset]=CLANG_TSAN_PRESET
                [--tsan-build-dir]=TSAN_BUILD_DIR [--profraw-dir]=PROFRAW_DIR
            ) ;;
        coverage)
            _ci_options=(
                [--workspace-dir]=WORKSPACE_DIR [--compiler]=COMPILER [--build-dir]=BUILD_DIR
                [--coverage-json]=COVERAGE_JSON [--profraw-dir]=PROFRAW_DIR
            ) ;;
        docs)
            _ci_options=(
                [--workspace-dir]=WORKSPACE_DIR [--compiler]=COMPILER [--runner]=RUNNER
                [--docs-out]=DOCS_OUT
            ) ;;
        init)
            _ci_options=(
                [--workspace-dir]=WORKSPACE_DIR [--compiler]=COMPILER [--runner]=RUNNER
                [--arch]=MATRIX_ARCH
            ) ;;
        profile-bench)
            _ci_options=(
                [--perf-timeout-seconds]=PERF_TIMEOUT_SECONDS [--smoke-seconds]=SMOKE_SECONDS
                [--signalling-port]=SIGNALLING_PORT [--build-dir]=BUILD_DIR [--compiler]=COMPILER
                [--gcc-profile-preset]=GCC_PROFILE_PRESET [--clang-profile-preset]=CLANG_PROFILE_PRESET
                [--profile-binary]=PROFILE_BINARY [--profile-args]=PROFILE_ARGS
            ) ;;
        python-bindings)
            _ci_options=(
                [--workspace-dir]=WORKSPACE_DIR [--out-dir]=OUT_DIR [--build-root]=BUILD_ROOT
                [--python-version]=PYTHON_VERSION [--compiler]=COMPILER
            ) ;;
        finalize)
            _ci_options=([--workspace-dir]=WORKSPACE_DIR) ;;
        run-all)
            _ci_options=(
                [--compiler]=COMPILER [--runner]=RUNNER [--arch]=MATRIX_ARCH
                [--build-type]=BUILD_TYPE [--build-dir]=BUILD_DIR
                [--build-release-dir]=BUILD_RELEASE_DIR [--gcc-debug-preset]=GCC_DEBUG_PRESET
                [--clang-debug-preset]=CLANG_DEBUG_PRESET [--gcc-profile-preset]=GCC_PROFILE_PRESET
                [--clang-profile-preset]=CLANG_PROFILE_PRESET [--clang-release-preset]=CLANG_RELEASE_PRESET
                [--coverage-json]=COVERAGE_JSON [--docs-out]=DOCS_OUT
                [--release-callgrind]=RELEASE_CALLGRIND [--release-appimage]=RELEASE_APPIMAGE
                [--release-flatpak]=RELEASE_FLATPAK [--release-appimage-out-dir]=RELEASE_APPIMAGE_OUT_DIR
                [--release-flatpak-out-dir]=RELEASE_FLATPAK_OUT_DIR
            ) ;;
        *) die "Unknown CI parser: ${_ci_lane}" ;;
    esac
    local -a _ci_remaining=()
    parse_cli_value_options _ci_options _ci_remaining ci_unknown_argument "$@"
    [ "${#_ci_remaining[@]}" -eq 0 ] || die "Unknown argument: ${_ci_remaining[0]}"
}

# Fetches resources/models/llm.lock into resources/models/ and prints the contract model's directory.
ci_fetch_llm_model() {
    local workspace="$1" fetcher
    fetcher="$(antfrastructure_path linux/scripts/lib/fetch-data-lock.py)" || return 1
    python3 -I "${fetcher}" --lock "${workspace}/resources/models/llm.lock" --extract >&2 || return 1
    printf '%s\n' "${workspace}/resources/models/smollm2_135m_instruct-cpu"
}
