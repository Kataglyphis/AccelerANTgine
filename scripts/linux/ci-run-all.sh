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
		*) die "Unknown argument: $1" ;;
	esac
done

info "=== CI Run All ==="
info "Compiler: ${COMPILER}  Runner: ${RUNNER}  Arch: ${MATRIX_ARCH}"

# clang links against the image's source-built GCC, and BOTH halves of that now
# come from the hub (01-core/cross-gcc.sh). gcc_toolchain_resolve_prefix answers
# the question gcc_toolchain_prefix() does not - which prefix on THIS machine
# actually holds a usable GCC: MYPROJECT_GCC_TOOLCHAIN_PATH, then GCC_PREFIX,
# then the versions.env prefix IF it really carries lib/gcc/*/*/crtbeginS.o,
# then the newest /opt/gcc-* that does. A half-installed prefix fails at LINK
# time naming crtbeginS.o and nothing else, which is invisible from here.
# export_clang_gcc_toolchain_env then writes the flags.
#
# This block used to compose them itself from the unprobed prefix, and got three
# things wrong that the hub helper does not: it set no CFLAGS (so C sources were
# built against the system GCC while C++ was not), it OVERWROTE any inherited
# CXXFLAGS/LDFLAGS instead of prepending, and it hard-coded lib64, which does not
# exist in a prefix that only has lib/. The helper gates on CC being a clang, so
# the compiler choice is stated here rather than implied - the presets pin
# CMAKE_C_COMPILER/CMAKE_CXX_COMPILER, so CC/CXX steer only the helper and the
# non-CMake tools, never the build.
if [[ "${COMPILER}" == "clang" ]]; then
	antfrastructure_source linux/scripts/01-core/cross-gcc.sh
	export CC="${CC:-clang}" CXX="${CXX:-clang++}"
	export_clang_gcc_toolchain_env
	info "GCC toolchain for clang: ${CROSS_GCC_TOOLCHAIN_PATH}"
fi

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
	--clang-debug-preset "${CLANG_DEBUG_PRESET}"

bash scripts/linux/ci-coverage.sh \
	--workspace-dir "$(pwd)" \
	--compiler "${COMPILER}" \
	--build-dir "${BUILD_DIR}" \
	--coverage-json "${COVERAGE_JSON}"

bash scripts/linux/run-static-analysis-format.sh \
	--build-dir "${BUILD_DIR}" \
	--compiler "${COMPILER}" \
	--clang-debug-preset "${CLANG_DEBUG_PRESET}"

bash scripts/linux/ci-profile-bench.sh \
	--build-dir "${BUILD_DIR}" \
	--compiler "${COMPILER}" \
	--gcc-profile-preset "${GCC_PROFILE_PRESET}" \
	--clang-profile-preset "${CLANG_PROFILE_PRESET}"

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
