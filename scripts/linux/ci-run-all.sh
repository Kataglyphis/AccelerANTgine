#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

COMPILER="clang"
RUNNER="ubuntu-26.04"
MATRIX_ARCH="x64"
BUILD_TYPE="Debug"
BUILD_DIR="build"
BUILD_RELEASE_DIR="build-release"
GCC_DEBUG_PRESET="linux-debug-GNU"
CLANG_DEBUG_PRESET="linux-debug-clang"
GCC_PROFILE_PRESET="linux-profile-GNU"
CLANG_PROFILE_PRESET="linux-profile-clang"
CLANG_RELEASE_PRESET="linux-release-clang"
COVERAGE_JSON="coverage.json"
DOCS_OUT="build/build/html"
RELEASE_CALLGRIND="0"
RELEASE_APPIMAGE="1"
RELEASE_FLATPAK="1"
RELEASE_APPIMAGE_OUT_DIR=""
RELEASE_FLATPAK_OUT_DIR=""
# all runs the parts in order; the lane runs one per step (BACKLOG step 10).
PART="all"

ci_parse_value_options run-all "$@"
antfrastructure_source linux/scripts/01-core/gates.sh

info "=== CI Run All (part: ${PART}) ==="
info "Compiler: ${COMPILER}  Runner: ${RUNNER}  Arch: ${MATRIX_ARCH}"

# Named once: ci-build-and-test.sh writes the raw profiles here and ci-coverage.sh merges them.
PROFRAW_DIR="${BUILD_DIR}/profraw"

# No --gcc-toolchain: the image's clang finds its GCC through the <native-triple>-clang++.cfg.
part_build_test() {
	rm -f "${BUILD_DIR}/.lane-built"
	bash scripts/linux/ci-init.sh \
		--workspace-dir "$(pwd)" \
		--compiler "${COMPILER}" \
		--runner "${RUNNER}" \
		--arch "${MATRIX_ARCH}"
	bash scripts/linux/ci-build-and-test.sh \
		--workspace-dir "$(pwd)" \
		--compiler "${COMPILER}" \
		--build-dir "${BUILD_DIR}" \
		--build-type "${BUILD_TYPE}" \
		--gcc-debug-preset "${GCC_DEBUG_PRESET}" \
		--clang-debug-preset "${CLANG_DEBUG_PRESET}" \
		--profraw-dir "${PROFRAW_DIR}"
	touch "${BUILD_DIR}/.lane-built"
	# The x64 lanes run on every push and own census rows; arm64 runs on request and gets its rows later.
	if [[ "${MATRIX_ARCH}" == "x64" ]]; then
		python3 "$(antfrastructure_path linux/scripts/verify_warning_census.py)" --lane "${MATRIX_ARCH}-${COMPILER}" \
			--census scripts/linux/warning-census.txt "${BUILD_DIR}/build.log"
	fi
}

part_coverage() {
	bash scripts/linux/ci-coverage.sh \
		--workspace-dir "$(pwd)" \
		--compiler "${COMPILER}" \
		--build-dir "${BUILD_DIR}" \
		--coverage-json "${COVERAGE_JSON}" \
		--profraw-dir "${PROFRAW_DIR}"
}

part_static() {
	bash scripts/linux/run-static-analysis-format.sh \
		--build-dir "${BUILD_DIR}" \
		--compiler "${COMPILER}" \
		--clang-debug-preset "${CLANG_DEBUG_PRESET}"
}

part_bench() {
	bash scripts/linux/ci-profile-bench.sh \
		--build-dir "${BUILD_DIR}" \
		--compiler "${COMPILER}" \
		--gcc-profile-preset "${GCC_PROFILE_PRESET}" \
		--clang-profile-preset "${CLANG_PROFILE_PRESET}"
}

part_python() {
	bash scripts/linux/ci-python-bindings.sh \
		--workspace-dir "$(pwd)" \
		--compiler "${COMPILER}" \
		--out-dir "dist/python"
}

# Every report of this leg at once, TSan and pytest included, so no lane's skip goes unread.
part_skips() {
	mapfile -t JUNIT_REPORTS < <(ci_junit_reports "${COMPILER}")
	python3 scripts/linux/check-junit-skips.py "${JUNIT_REPORTS[@]}" \
		|| die "A test skipped or a JUnit report is missing (listed above)."
}

part_release() {
	local release_args=(
		--workspace-dir "$(pwd)"
		--compiler "${COMPILER}"
		--build-release-dir "${BUILD_RELEASE_DIR}"
		--clang-release-preset "${CLANG_RELEASE_PRESET}"
	)
	if [[ "${RELEASE_CALLGRIND}" == "1" ]]; then
		release_args+=(--callgrind)
	fi
	if [[ "${RELEASE_APPIMAGE}" == "1" ]]; then
		release_args+=(--appimage)
	else
		release_args+=(--no-appimage)
	fi
	if [[ "${RELEASE_FLATPAK}" == "1" ]]; then
		release_args+=(--flatpak)
	else
		release_args+=(--no-flatpak)
	fi
	if [[ -n "${RELEASE_APPIMAGE_OUT_DIR}" ]]; then
		release_args+=(--appimage-out-dir "${RELEASE_APPIMAGE_OUT_DIR}")
	fi
	if [[ -n "${RELEASE_FLATPAK_OUT_DIR}" ]]; then
		release_args+=(--flatpak-out-dir "${RELEASE_FLATPAK_OUT_DIR}")
	fi
	bash scripts/linux/ci-release.sh "${release_args[@]}"
}

# After the packages: a failed docs build no longer costs the run its packages and wheels (owner D6).
part_docs() {
	bash scripts/linux/ci-docs.sh \
		--workspace-dir "$(pwd)" \
		--compiler "${COMPILER}" \
		--runner "${RUNNER}" \
		--docs-out "${DOCS_OUT}"
	bash scripts/linux/ci-finalize.sh --workspace-dir "$(pwd)"
}

# By name, so each part's function has a caller the dead-function gate can see.
run_part() {
	case "$1" in
		build-test) part_build_test ;;
		coverage) part_coverage ;;
		static) part_static ;;
		bench) part_bench ;;
		python) part_python ;;
		skips) part_skips ;;
		release) part_release ;;
		docs) part_docs ;;
		*) die "Unknown part: $1" ;;
	esac
}

PARTS=(build-test coverage static bench)
# One leg is enough: the wheels do not depend on the lane's compiler, and the clang leg uploads them.
if [[ "${COMPILER}" == "clang" ]]; then
	PARTS+=(python)
fi
PARTS+=(skips release docs)

gate_reset "lane parts"
if [[ "${PART}" == "all" ]]; then
	run_gate "lane part: build-test" run_part build-test
	for part in "${PARTS[@]:1}"; do
		# The lane's steps skip the same way: nothing after a failed build has a build to read.
		if [[ ! -f "${BUILD_DIR}/.lane-built" ]]; then
			gate_skip "lane part: ${part}" "the build failed"
		else
			run_gate "lane part: ${part}" run_part "${part}"
		fi
	done
elif [[ " ${PARTS[*]} " == *" ${PART} "* ]]; then
	run_gate "lane part: ${PART}" run_part "${PART}"
else
	die "Unknown part: ${PART} (one of: all ${PARTS[*]})"
fi
assert_gates

info "=== CI Run All complete (part: ${PART}) ==="
