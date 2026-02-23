#!/usr/bin/env bash
set -euo pipefail

COMPILER="clang"
RUNNER="ubuntu-24.04"
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

while [[ $# -gt 0 ]]; do
	case "$1" in
		--compiler) COMPILER="${2:-}"; shift 2 ;;
		--runner) RUNNER="${2:-}"; shift 2 ;;
		--arch) MATRIX_ARCH="${2:-}"; shift 2 ;;
		--build-type) BUILD_TYPE="${2:-}"; shift 2 ;;
		--build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
		--build-release-dir) BUILD_RELEASE_DIR="${2:-}"; shift 2 ;;
		--gcc-debug-preset) GCC_DEBUG_PRESET="${2:-}"; shift 2 ;;
		--clang-debug-preset) CLANG_DEBUG_PRESET="${2:-}"; shift 2 ;;
		--gcc-profile-preset) GCC_PROFILE_PRESET="${2:-}"; shift 2 ;;
		--clang-profile-preset) CLANG_PROFILE_PRESET="${2:-}"; shift 2 ;;
		--clang-release-preset) CLANG_RELEASE_PRESET="${2:-}"; shift 2 ;;
		--coverage-json) COVERAGE_JSON="${2:-}"; shift 2 ;;
		--docs-out) DOCS_OUT="${2:-}"; shift 2 ;;
		--release-callgrind) RELEASE_CALLGRIND="${2:-}"; shift 2 ;;
		--release-appimage) RELEASE_APPIMAGE="${2:-}"; shift 2 ;;
		--release-flatpak) RELEASE_FLATPAK="${2:-}"; shift 2 ;;
		--release-appimage-out-dir) RELEASE_APPIMAGE_OUT_DIR="${2:-}"; shift 2 ;;
		--release-flatpak-out-dir) RELEASE_FLATPAK_OUT_DIR="${2:-}"; shift 2 ;;
		*)
			echo "Unknown argument: $1" >&2
			exit 2
			;;
	esac
done

export COMPILER
export RUNNER
export MATRIX_ARCH
export BUILD_TYPE
export BUILD_DIR
export BUILD_RELEASE_DIR
export GCC_DEBUG_PRESET
export CLANG_DEBUG_PRESET
export GCC_PROFILE_PRESET
export CLANG_PROFILE_PRESET
export CLANG_RELEASE_PRESET
export COVERAGE_JSON
export DOCS_OUT
export RELEASE_CALLGRIND
export RELEASE_APPIMAGE
export RELEASE_FLATPAK
export RELEASE_APPIMAGE_OUT_DIR
export RELEASE_FLATPAK_OUT_DIR

bash scripts/linux/ci_init.sh
bash scripts/linux/ci_build_and_test.sh
bash scripts/linux/ci_coverage.sh
bash scripts/linux/ci_static_analysis.sh
bash scripts/linux/ci_profile_bench.sh
bash scripts/linux/ci_docs.sh

release_args=(
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

bash scripts/linux/ci_release.sh "${release_args[@]}"
bash scripts/linux/ci_finalize.sh
