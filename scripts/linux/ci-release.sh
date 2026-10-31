#!/usr/bin/env bash
# ci-release.sh - release build, CPack and Flatpak over ANTfrastructure's cmake-build.sh and app-packaging.sh.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source (via ci-common.sh) honours the ANTFRASTRUCTURE_DIR override.
antfrastructure_source linux/scripts/01-core/tool-checks.sh
antfrastructure_source linux/scripts/lib/cmake-build.sh
antfrastructure_source linux/scripts/lib/app-packaging.sh

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"

BUILD_RELEASE_DIR="build-release"
CLANG_RELEASE_PRESET="linux-release-clang"
ORT_VARIANT=cpu
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

# Not defaulted: a hub that stopped publishing the pin must fail, not fall back to a stale number.
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
  --ort-variant <name>          cpu, nvidia or amd (default: cpu; GPU requires --no-flatpak)
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
# Each package must carry the project license, ONNX Runtime's texts, the notices a fresh install writes and the logo.
verify_release_licenses() {
  local build_dir="$1" reference artifact verifier appimage_verifier member
  local -A icons=(
    ["share/icons/hicolor/256x256/apps/${APP_ID}.png"]="${WORKSPACE_DIR}/images/logo.png"
    ["share/icons/hicolor/scalable/apps/${APP_ID}.svg"]="${WORKSPACE_DIR}/images/logo.svg")
  local -a rules=() names=(
    "share/licenses/${PROJECT_NAME_META}/THIRD-PARTY-NOTICES.txt"
    "share/licenses/${PROJECT_NAME_META}/LICENSE"
    "share/licenses/onnxruntime/LICENSE"
    "share/licenses/onnxruntime/ThirdPartyNotices.txt")
  verifier="$(antfrastructure_path linux/scripts/verify_package_license.py)"
  appimage_verifier="$(antfrastructure_path linux/scripts/06-packaging/verify-native-appimage-license.sh)"
  reference="$(mktemp -d)"
  cmake --install "${build_dir}" --prefix "${reference}/usr" > /dev/null
  for member in "${names[@]}"; do
    [[ -s "${reference}/usr/${member}" ]] || die "the install tree lacks ${member}"
    rules+=(--require "*${member}=${reference}/usr/${member}")
  done
  for member in "${!icons[@]}"; do
    rules+=(--require "*${member}=${icons[${member}]}")
  done
  shopt -s nullglob
  local -a artifacts=("${build_dir}"/*.deb "${build_dir}"/*.tar.gz "${build_dir}"/*.flatpak "${build_dir}"/*.AppImage)
  shopt -u nullglob
  [[ "${#artifacts[@]}" -gt 0 ]] || die "no release package to check for licenses in ${build_dir}"
  for artifact in "${artifacts[@]}"; do
    if [[ "${artifact}" == *.AppImage ]]; then
      for member in "${names[@]}"; do
        bash "${appimage_verifier}" "${artifact}" "$(uname -m)" "usr/${member}" "${reference}/usr/${member}" ||
          die "${artifact##*/} lacks ${member}"
      done
      for member in "${!icons[@]}"; do
        bash "${appimage_verifier}" "${artifact}" "$(uname -m)" "usr/${member}" "${icons[${member}]}" ||
          die "${artifact##*/} lacks the project logo ${member}"
      done
    else
      python3 "${verifier}" "${artifact}" "${rules[@]}" || die "${artifact##*/} lacks a license text"
    fi
    info "licenses verified: ${artifact##*/}"
  done
  rm -rf -- "${reference}"
}

# Not the hub's container helper: this also runs on a dev box, where AUTO_INSTALL_FLATPAK and sudo apt apply.
ensure_flatpak_tools() {
  local -a missing_cmds=()
  if ! has_tool flatpak-builder; then
    missing_cmds+=("flatpak-builder")
  fi
  if ! has_tool flatpak; then
    missing_cmds+=("flatpak")
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
    --ort-variant)
      ORT_VARIANT="${2:?--ort-variant expects a value}"
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

case "${ORT_VARIANT}" in
  cpu) ;;
  nvidia|amd)
    [[ "${DO_FLATPAK}" -eq 0 ]] || die "GPU package variants require --no-flatpak"
    ;;
  *) die "Unknown ONNX Runtime package variant: ${ORT_VARIANT}" ;;
esac

if [[ "${COMPILER:-}" != "clang" ]]; then
  info "Skipping release packaging for compiler '${COMPILER:-unknown}'"
  exit 0
fi

CPACK_APPIMAGE_FLAG="ON"
if [[ "${DO_APPIMAGE}" -ne 1 ]]; then
  CPACK_APPIMAGE_FLAG="OFF"
fi

info "Building release with preset: ${CLANG_RELEASE_PRESET}"

# The /workspace safe.directory default is wrong on a dev box, where `git rev-parse` would then refuse.
CMAKE_BUILD_SAFE_DIRECTORY="${WORKSPACE_DIR}"
gpu_configure_args=()
if [[ "${ORT_VARIANT}" != cpu ]]; then
  gpu_configure_args=(--configure-arg "-DKATAGLYPHIS_ORT_VARIANT=${ORT_VARIANT}")
fi
cmake_build_main \
  --preset "${CLANG_RELEASE_PRESET}" \
  --build-dir "${BUILD_RELEASE_DIR}" \
  --clean-build-dir true \
  --mb-per-job 2000 \
  --configure-arg "-DCMAKE_LINK_WHAT_YOU_USE=FALSE" \
  --configure-arg "-DCPACK_ENABLE_APPIMAGE=${CPACK_APPIMAGE_FLAG}" \
  "${gpu_configure_args[@]}"

# Validate AppStream metadata without depending on website availability.
AS_VALIDATE_NONET=1 cmake --build "${BUILD_RELEASE_DIR}" --target package

if [[ "${DO_FLATPAK}" -eq 1 ]]; then
  [[ -n "${FLATPAK_OUT_DIR}" ]] || FLATPAK_OUT_DIR="${BUILD_RELEASE_DIR}"
  if ! ensure_flatpak_tools; then
    if [[ "${FLATPAK_EXPLICIT}" -eq 1 ]]; then
      die "Flatpak requested but required tools are unavailable."
    fi
    warn "Skipping Flatpak build (required tools are unavailable)."
    warn "Install flatpak + flatpak-builder or run with --no-flatpak to suppress this warning."
  else
    load_project_metadata "${BUILD_RELEASE_DIR}"
    # A separate step: installing a runtime changes the machine, so a caller must be able to skip it.
    app_packaging_ensure_flatpak_runtime \
      "${FLATPAK_ARCH}" "${FLATPAK_RUNTIME}" "${FLATPAK_SDK}" "${FLATPAK_RUNTIME_VERSION}"
    # FLATPAK_ARCH stays raw: empty means "this machine", with no --arch pinned.
    app_packaging_package_cmake_install_flatpak \
      "${BUILD_RELEASE_DIR}" "${FLATPAK_OUT_DIR}" "${APP_ID}" \
      "${PROJECT_NAME_META}" "${VERSION_SUFFIX_META}" \
      "${FLATPAK_RUNTIME}" "${FLATPAK_SDK}" "${FLATPAK_RUNTIME_VERSION}" \
      "${FLATPAK_BRANCH}" "${FLATPAK_ARCH}"
  fi
fi

load_project_metadata "${BUILD_RELEASE_DIR}"
verify_release_licenses "${BUILD_RELEASE_DIR}"
bash "${_SCRIPT_DIR}/verify-package-hardening.sh" "${BUILD_RELEASE_DIR}" || die "the release packages are not hardened"

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
