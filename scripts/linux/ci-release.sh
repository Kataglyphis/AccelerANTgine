#!/usr/bin/env bash
# ci-release.sh - project wrapper around ANTfrastructure's CMake and packaging
# libraries.
#
# WHAT COMES FROM UPSTREAM NOW:
#   * linux/scripts/lib/cmake-build.sh    - the container environment repair
#     (git safe.directory, the CCACHE_SECONDARY_STORAGE-is-not-a-URL fix,
#     writable CARGO_HOME/SCCACHE_DIR/CCACHE_DIR) and the memory-aware job count.
#     This file used to call compute_jobs_with_mem_cap itself and export
#     CMAKE_BUILD_PARALLEL_LEVEL; it does neither now.
#     AND THE CONFIGURE LINE, as of 2015e12f: --configure-arg is repeatable and
#     order-preserving and reaches the configure step only, so the block this
#     header used to describe - parse_args / prepare_env / run with the configure
#     step skipped, plus a hand-written `cmake -B ... --preset` carrying the two
#     -D flags this lane needs - is one cmake_build_main call. The local tree
#     wipe went back to --clean-build-dir true with it: cmake_build_run cleans
#     BEFORE it configures, which is the order that made a local configure unsafe.
#   * linux/scripts/lib/app-packaging.sh  - the flatpak architecture mapping,
#     the "an artifact that is missing or empty is not a success" assertion, and
#     as of 0e054bbd THE WHOLE FLATPAK BUNDLE: app_packaging_ensure_flatpak_runtime
#     and app_packaging_package_cmake_install_flatpak are the cmake-install twin
#     this header used to say did not exist. Two deliberate differences from the
#     local pair they replace, both improvements this lane wants:
#       - staging is CONTAINER-NATIVE (KATAGLYPHIS_FLATPAK_WORKDIR, default
#         /tmp/flatpak-work) and only the finished bundle is copied to <out_dir>.
#         The local version staged under <build_dir>/flatpak, which on a mounted
#         Windows workspace is a bind mount, and everything flatpak touches wants
#         fchmod - which a bind mount refuses;
#       - OSTREE decides, not flatpak-builder's exit code. A complete export can
#         exit non-zero on a late chmod, and a zero exit can leave an empty repo;
#         the local version believed the exit code for both.
#   * linux/scripts/01-core/tool-checks.sh - has_tool, which replaced a local
#     require_cmd that reported only the first missing tool. require_tools came
#     with it and has no caller left in this file: both functions that used it
#     are the ones app-packaging.sh owns now.
#   * FLATPAK_RUNTIME_VERSION - a hub pin in 01-core/versions.env, already
#     exported by the time ci-common.sh returns. The literal 24.08 that used to
#     sit at the top of this file is gone: it drifted from the pin silently.
#
# WHAT IS STILL LOCAL, AND WHY:
#   * load_project_metadata. The hub packager takes the project name and the
#     version suffix as ARGUMENTS and nothing upstream reads CMakeCache.txt, so
#     this stays - as does the fallback chain (cache, then the short git sha,
#     then "unknown"), which is this project's naming convention and not a
#     packaging concern.
#   * ensure_flatpak_tools' apt/AUTO_INSTALL knob. The hub's container helper
#     assumes an image that already ships the packaging prerequisites and runs
#     apt through a privilege helper; this script is also run on a dev box.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source, not a "${_SCRIPT_DIR}/../../third_party/ANTfrastructure/..."
# literal: it resolves under ANTFRASTRUCTURE_DIR and fails naming the probed path
# and the fix. In scope because ci-common.sh sources lib/antfrastructure.sh.
antfrastructure_source linux/scripts/01-core/tool-checks.sh
antfrastructure_source linux/scripts/lib/cmake-build.sh
antfrastructure_source linux/scripts/lib/app-packaging.sh

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"

BUILD_RELEASE_DIR="build-release"
CLANG_RELEASE_PRESET="linux-release-clang"
DO_CALLGRIND=0
DO_APPIMAGE=1
DO_FLATPAK=1
FLATPAK_EXPLICIT=0
FLATPAK_OUT_DIR=""
FLATPAK_RUNTIME="org.freedesktop.Platform"
FLATPAK_SDK="org.freedesktop.Sdk"
FLATPAK_BRANCH="master"
AUTO_INSTALL_FLATPAK="1"
FLATPAK_ARCH=""
APP_ID="org.kataglyphis.accelerantgine"

# Not defaulted here on purpose - see the header. A hub that stopped publishing
# the pin must fail loudly rather than fall back to a number nobody maintains.
[[ -n "${FLATPAK_RUNTIME_VERSION:-}" ]] ||
  die "FLATPAK_RUNTIME_VERSION is unset: ANTfrastructure linux/scripts/01-core/versions.env no longer publishes it."

usage() {
  cat <<EOF
Usage: ci-release.sh [options]

Options:
  --workspace-dir <dir>         Workspace directory (default: current dir)
  --compiler <name>             Compiler label (default: clang)
  --build-release-dir <dir>     Build directory (default: build-release)
  --clang-release-preset <name> CMake preset (default: linux-release-clang)
  --callgrind                   Run valgrind/callgrind (default: off)
  --appimage                    Build AppImage (default: on)
  --no-appimage                 Disable AppImage build
  --flatpak|--flatpack          Build Flatpak bundle (default: on)
  --no-flatpak|--no-flatpack    Disable Flatpak build
  --flatpak-out-dir <dir>       Flatpak output directory (default: build dir)
  --flatpak-runtime <name>      Flatpak runtime (default: org.freedesktop.Platform)
  --flatpak-runtime-version <v> Flatpak runtime branch (default: ANTfrastructure
                                versions.env FLATPAK_RUNTIME_VERSION, currently
                                ${FLATPAK_RUNTIME_VERSION})
  --flatpak-sdk <name>          Flatpak SDK (default: org.freedesktop.Sdk)
  --flatpak-branch <name>       Flatpak branch (default: master)
  --flatpak-arch <name>         Flatpak arch override (default: auto-detect)
  --auto-install-flatpak <0|1>  Auto-install flatpak tools (default: 1)
  -h, --help                    Show help
EOF
}

read_cache_var() {
  local cache_file="$1"
  local key="$2"
  local line
  line="$(grep -E "^${key}:[^=]*=" "$cache_file" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$line" ]]; then
    echo "${line#*=}"
  fi
}

load_project_metadata() {
  local build_dir="$1"
  local cache_file="${build_dir}/CMakeCache.txt"
  local project_name="KataglyphisCppProject"
  local project_version=""

  if [[ -f "${cache_file}" ]]; then
    project_name="$(read_cache_var "${cache_file}" CMAKE_PROJECT_NAME || true)"
    project_version="$(read_cache_var "${cache_file}" CMAKE_PROJECT_VERSION || true)"
  fi

  [[ -n "${project_name}" ]] || project_name="KataglyphisCppProject"

  local git_sha
  git_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"

  PROJECT_NAME_META="${project_name}"
  VERSION_SUFFIX_META="${project_version:-${git_sha:-unknown}}"
}
# Deliberately NOT the hub's app_packaging_setup_dependencies_for_container: that
# one assumes the CI image already ships flatpak/flatpak-builder and installs
# through a privilege helper. This script also runs on a dev box, where the
# AUTO_INSTALL_FLATPAK knob and plain sudo apt are the right answer.
#
# OSTREE IS IN THE LIST because the hub packager's verdict is `ostree refs`, not
# flatpak-builder's exit code, and app_packaging_require_flatpak_tools checks
# only flatpak and flatpak-builder. Debian's flatpak depends on libostree, not on
# the ostree binary, so a dev box without the CLI reports "not committed" over a
# good export. The family CI image already ships all three.
ensure_flatpak_tools() {
  local -a missing_cmds=()
  if ! has_tool flatpak-builder; then
    missing_cmds+=("flatpak-builder")
  fi
  if ! has_tool flatpak; then
    missing_cmds+=("flatpak")
  fi
  if ! has_tool ostree; then
    missing_cmds+=("ostree")
  fi
  if [[ "${#missing_cmds[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${AUTO_INSTALL_FLATPAK}" != "1" ]]; then
    warn "Missing required command(s): ${missing_cmds[*]}"
    return 1
  fi

  if ! has_tool apt-get; then
    warn "Missing required command(s): ${missing_cmds[*]}"
    warn "Automatic install is only supported with apt-get."
    return 1
  fi

  warn "Missing Flatpak tools (${missing_cmds[*]}). Trying automatic installation via apt..."

  require_sudo
  apt_install flatpak flatpak-builder ostree elfutils

  if ! has_tool flatpak-builder || ! has_tool flatpak || ! has_tool ostree; then
    warn "Automatic Flatpak tool installation failed."
    return 1
  fi

  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-release-dir)
      BUILD_RELEASE_DIR="$2"
      shift 2
      ;;
    --workspace-dir)
      WORKSPACE_DIR="$2"
      shift 2
      ;;
    --compiler)
      COMPILER="$2"
      shift 2
      ;;
    --clang-release-preset)
      CLANG_RELEASE_PRESET="$2"
      shift 2
      ;;
    --flatpak-runtime)
      FLATPAK_RUNTIME="$2"
      shift 2
      ;;
    --flatpak-runtime-version)
      FLATPAK_RUNTIME_VERSION="$2"
      shift 2
      ;;
    --flatpak-sdk)
      FLATPAK_SDK="$2"
      shift 2
      ;;
    --flatpak-branch)
      FLATPAK_BRANCH="$2"
      shift 2
      ;;
    --auto-install-flatpak)
      AUTO_INSTALL_FLATPAK="$2"
      shift 2
      ;;
    --flatpak-arch)
      FLATPAK_ARCH="$2"
      shift 2
      ;;
    --callgrind)
      DO_CALLGRIND=1
      shift 1
      ;;
    --appimage)
      DO_APPIMAGE=1
      shift 1
      ;;
    --no-appimage)
      DO_APPIMAGE=0
      shift 1
      ;;
    --flatpak|--flatpack)
      DO_FLATPAK=1
      FLATPAK_EXPLICIT=1
      shift 1
      ;;
    --no-flatpak|--no-flatpack)
      DO_FLATPAK=0
      shift 1
      ;;
    --flatpak-out-dir)
      FLATPAK_OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ "${COMPILER:-}" != "clang" ]]; then
  info "Skipping release packaging for compiler '${COMPILER:-unknown}'"
  exit 0
fi

CPACK_APPIMAGE_FLAG="ON"
if [[ "${DO_APPIMAGE}" -ne 1 ]]; then
  CPACK_APPIMAGE_FLAG="OFF"
fi

info "Building release with preset: ${CLANG_RELEASE_PRESET}"

# ONE call now, where parse_args / prepare_env / run plus a hand-written
# `cmake -B ... --preset` used to sit. --clean-build-dir is true again because
# cmake_build_run cleans BEFORE it configures; the false plus a local wipe
# existed only because the configure was issued down here. The lane still starts
# from nothing, so the behaviour is unchanged.
#
# The two --configure-arg flags reach the CONFIGURE step only, in order, and are
# NOT forwarded to `cmake --build`. CMAKE_BUILD_SAFE_DIRECTORY is set first
# because cmake_build_main runs cmake_build_prepare_env, whose /workspace default
# is wrong on a dev box: load_project_metadata's `git rev-parse` would refuse it.
CMAKE_BUILD_SAFE_DIRECTORY="${WORKSPACE_DIR}"
cmake_build_main \
  --preset "${CLANG_RELEASE_PRESET}" \
  --build-dir "${BUILD_RELEASE_DIR}" \
  --clean-build-dir true \
  --mb-per-job 2000 \
  --configure-arg "-DCMAKE_LINK_WHAT_YOU_USE=FALSE" \
  --configure-arg "-DCPACK_ENABLE_APPIMAGE=${CPACK_APPIMAGE_FLAG}"

cmake --build "${BUILD_RELEASE_DIR}" --target package

if [[ "${DO_FLATPAK}" -eq 1 ]]; then
  [[ -n "${FLATPAK_OUT_DIR}" ]] || FLATPAK_OUT_DIR="${BUILD_RELEASE_DIR}"
  if ! ensure_flatpak_tools; then
    if [[ "${FLATPAK_EXPLICIT}" -eq 1 ]]; then
      die "Flatpak requested but required tools are unavailable."
    fi
    warn "Skipping Flatpak build (required tools are unavailable)."
    warn "Install flatpak + flatpak-builder or run with --no-flatpak to suppress this warning."
  else
    # The project name and the version suffix are ARGUMENTS to the hub packager,
    # so the metadata read that used to sit inside build_flatpak happens here.
    load_project_metadata "${BUILD_RELEASE_DIR}"
    # Not folded into the packager upstream, and deliberately so: installing a
    # runtime is a side effect on the machine, and a caller that manages its own
    # runtimes must be able to skip it.
    app_packaging_ensure_flatpak_runtime \
      "${FLATPAK_ARCH}" "${FLATPAK_RUNTIME}" "${FLATPAK_SDK}" "${FLATPAK_RUNTIME_VERSION}"
    # FLATPAK_ARCH is passed RAW, empty included. Empty means "this machine",
    # which is what the local packager always did - it never passed --arch to
    # flatpak-builder at all. Passing the RESOLVED arch instead would start
    # pinning every default build to a spelling nobody asked for.
    app_packaging_package_cmake_install_flatpak \
      "${BUILD_RELEASE_DIR}" "${FLATPAK_OUT_DIR}" "${APP_ID}" \
      "${PROJECT_NAME_META}" "${VERSION_SUFFIX_META}" \
      "${FLATPAK_RUNTIME}" "${FLATPAK_SDK}" "${FLATPAK_RUNTIME_VERSION}" \
      "${FLATPAK_BRANCH}" "${FLATPAK_ARCH}"
  fi
fi

if [[ "${DO_CALLGRIND}" -eq 1 ]]; then
  if ! has_tool valgrind; then
    warn "valgrind not found, skipping callgrind."
    exit 0
  fi
  (
    cd "${BUILD_RELEASE_DIR}"
    ./bin/AccelerANTgine >/dev/null 2>&1 || true
    valgrind --tool=callgrind ./bin/AccelerANTgine
  )
fi
