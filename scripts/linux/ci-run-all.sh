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

ci_parse_value_options run-all "$@"

info "=== CI Run All ==="
info "Compiler: ${COMPILER}  Runner: ${RUNNER}  Arch: ${MATRIX_ARCH}"

# No --gcc-toolchain: the image's clang finds its GCC through the <native-triple>-clang++.cfg.

bash scripts/linux/ci-init.sh \
	--workspace-dir "$(pwd)" \
	--compiler "${COMPILER}" \
	--runner "${RUNNER}" \
	--arch "${MATRIX_ARCH}"

# Named once: ci-build-and-test.sh writes the raw profiles here and ci-coverage.sh merges them.
PROFRAW_DIR="${BUILD_DIR}/profraw"

bash scripts/linux/ci-build-and-test.sh \
	--workspace-dir "$(pwd)" \
	--compiler "${COMPILER}" \
	--build-dir "${BUILD_DIR}" \
	--build-type "${BUILD_TYPE}" \
	--gcc-debug-preset "${GCC_DEBUG_PRESET}" \
	--clang-debug-preset "${CLANG_DEBUG_PRESET}" \
	--profraw-dir "${PROFRAW_DIR}"

bash scripts/linux/ci-coverage.sh \
	--workspace-dir "$(pwd)" \
	--compiler "${COMPILER}" \
	--build-dir "${BUILD_DIR}" \
	--coverage-json "${COVERAGE_JSON}" \
	--profraw-dir "${PROFRAW_DIR}"

bash scripts/linux/run-static-analysis-format.sh \
	--build-dir "${BUILD_DIR}" \
	--compiler "${COMPILER}" \
	--clang-debug-preset "${CLANG_DEBUG_PRESET}"

bash scripts/linux/ci-profile-bench.sh \
	--build-dir "${BUILD_DIR}" \
	--compiler "${COMPILER}" \
	--gcc-profile-preset "${GCC_PROFILE_PRESET}" \
	--clang-profile-preset "${CLANG_PROFILE_PRESET}"

# One leg is enough: the wheels do not depend on the lane's compiler, and the clang leg uploads them.
if [[ "${COMPILER}" == "clang" ]]; then
	bash scripts/linux/ci-python-bindings.sh \
		--workspace-dir "$(pwd)" \
		--compiler "${COMPILER}" \
		--out-dir "dist/python"
fi

bash scripts/linux/ci-docs.sh \
	--workspace-dir "$(pwd)" \
	--compiler "${COMPILER}" \
	--runner "${RUNNER}" \
	--docs-out "${DOCS_OUT}"

release_args=(
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
bash scripts/linux/ci-finalize.sh --workspace-dir "$(pwd)"

info "=== CI Run All complete ==="
