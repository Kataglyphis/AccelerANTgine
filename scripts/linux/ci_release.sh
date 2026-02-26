#!/usr/bin/env bash
set -euo pipefail

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
FLATPAK_RUNTIME_VERSION="24.08"
FLATPAK_SDK="org.freedesktop.Sdk"
FLATPAK_BRANCH="master"
AUTO_INSTALL_FLATPAK="1"
FLATPAK_ARCH=""
APP_ID="org.kataglyphis.kataglyphiscppinference"

usage() {
  cat <<'EOF'
Usage: ci_release.sh [options]

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
  --flatpak-runtime-version <v> Flatpak runtime version (default: 24.08)
  --flatpak-sdk <name>          Flatpak SDK (default: org.freedesktop.Sdk)
  --flatpak-branch <name>       Flatpak branch (default: master)
  --flatpak-arch <name>         Flatpak arch override (default: auto-detect)
  --auto-install-flatpak <0|1>  Auto-install flatpak tools (default: 1)
  -h, --help                    Show help
EOF
}

require_cmd() {
  local cmd="$1"
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]]
    return
  fi
  command -v "$cmd" >/dev/null 2>&1
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "$(uname -m)" ;;
  esac
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

normalize_installed_file() {
  local dir="$1"
  local from_name="$2"
  local to_name="$3"
  local source=""

  if [[ -f "${dir}/${from_name}" ]]; then
    source="${dir}/${from_name}"
  elif [[ -f "${dir}/${to_name}" ]]; then
    source="${dir}/${to_name}"
  fi

  if [[ -n "${source}" && "${source}" != "${dir}/${to_name}" ]]; then
    cp -f "${source}" "${dir}/${to_name}"
    rm -f "${source}"
  fi
}

run_privileged_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Missing privileges for: $*" >&2
    return 1
  fi
}

ensure_flatpak_tools() {
  local -a missing_cmds=()
  if ! command -v flatpak-builder >/dev/null 2>&1; then
    missing_cmds+=("flatpak-builder")
  fi
  if ! command -v flatpak >/dev/null 2>&1; then
    missing_cmds+=("flatpak")
  fi
  if [[ "${#missing_cmds[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${AUTO_INSTALL_FLATPAK}" != "1" ]]; then
    echo "Missing required command(s): ${missing_cmds[*]}" >&2
    return 1
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Missing required command(s): ${missing_cmds[*]}" >&2
    echo "Automatic install is only supported with apt-get." >&2
    return 1
  fi

  echo "Missing Flatpak tools (${missing_cmds[*]}). Trying automatic installation via apt..." >&2

  if [[ "${EUID}" -eq 0 ]]; then
    apt-get update
    apt-get install -y flatpak flatpak-builder
  else
    if ! command -v sudo >/dev/null 2>&1; then
      echo "sudo is required for automatic installation but was not found." >&2
      return 1
    fi
    sudo apt-get update
    sudo apt-get install -y flatpak flatpak-builder
  fi

  if ! command -v flatpak-builder >/dev/null 2>&1 || ! command -v flatpak >/dev/null 2>&1; then
    echo "Automatic Flatpak tool installation failed." >&2
    return 1
  fi

  return 0
}

ensure_flatpak_runtime() {
  require_cmd flatpak

  local flatpak_arch="${FLATPAK_ARCH}"
  if [[ -z "${flatpak_arch}" ]]; then
    flatpak_arch="$(flatpak --default-arch 2>/dev/null || true)"
  fi
  if [[ -z "${flatpak_arch}" ]]; then
    flatpak_arch="$(normalize_arch)"
  fi

  local runtime_ref="${FLATPAK_RUNTIME}/${flatpak_arch}/${FLATPAK_RUNTIME_VERSION}"
  local sdk_ref="${FLATPAK_SDK}/${flatpak_arch}/${FLATPAK_RUNTIME_VERSION}"

  if ! flatpak remote-info --user flathub >/dev/null 2>&1 && ! flatpak remote-info --system flathub >/dev/null 2>&1; then
    if ! flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1; then
      flatpak --system remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
  fi

  if ! flatpak info --user "${runtime_ref}" >/dev/null 2>&1; then
    flatpak --user install -y --noninteractive flathub "${runtime_ref}" ||
      flatpak --system install -y --noninteractive flathub "${runtime_ref}"
  fi

  if ! flatpak info --user "${sdk_ref}" >/dev/null 2>&1; then
    flatpak --user install -y --noninteractive flathub "${sdk_ref}" ||
      flatpak --system install -y --noninteractive flathub "${sdk_ref}"
  fi
}

build_flatpak() {
  local build_dir="$1"
  local out_dir="$2"
  require_cmd flatpak-builder
  require_cmd flatpak
  ensure_flatpak_runtime

  load_project_metadata "${build_dir}"
  local project_name="${PROJECT_NAME_META}"
  local version_suffix="${VERSION_SUFFIX_META}"

  local app_id="${APP_ID}"
  local flatpak_root="${build_dir}/flatpak"
  local source_dir="${flatpak_root}/source"
  local build_root="${flatpak_root}/build"
  local repo_dir="${flatpak_root}/repo"
  local manifest_path="${flatpak_root}/${app_id}.json"

  rm -rf "${flatpak_root}"
  mkdir -p "${source_dir}/app" "${build_root}" "${repo_dir}" "${out_dir}"
  cmake --install "${build_dir}" --prefix "${source_dir}/app"

  local desktop_dir="${source_dir}/app/share/applications"
  local icon_dir="${source_dir}/app/share/icons/hicolor/256x256/apps"
  local metainfo_dir="${source_dir}/app/share/metainfo"
  normalize_installed_file "${desktop_dir}" "${project_name}.desktop" "${app_id}.desktop"
  normalize_installed_file "${icon_dir}" "${project_name}.png" "${app_id}.png"
  normalize_installed_file "${metainfo_dir}" "${project_name}.appdata.xml" "${app_id}.appdata.xml"

  local source_app_path
  source_app_path="$(cd "${source_dir}/app" && pwd)"

  if [[ ! -x "${source_dir}/app/bin/${project_name}" ]]; then
    echo "Flatpak staging failed: expected executable at ${source_dir}/app/bin/${project_name}" >&2
    return 1
  fi

  cat >"${manifest_path}" <<EOF
{
  "app-id": "${app_id}",
  "runtime": "${FLATPAK_RUNTIME}",
  "runtime-version": "${FLATPAK_RUNTIME_VERSION}",
  "sdk": "${FLATPAK_SDK}",
  "command": "${project_name}",
  "modules": [
    {
      "name": "${project_name}",
      "buildsystem": "simple",
      "build-commands": [
        "cp -a . /app"
      ],
      "sources": [
        {
          "type": "dir",
          "path": "${source_app_path}"
        }
      ]
    }
  ]
}
EOF

  flatpak-builder --disable-rofiles-fuse --force-clean --repo="${repo_dir}" "${build_root}" "${manifest_path}"

  local out_name="${project_name}-${version_suffix}-linux.flatpak"
  flatpak build-bundle "${repo_dir}" "${out_dir}/${out_name}" "${app_id}" "${FLATPAK_BRANCH}"
  echo "Flatpak bundle written: ${out_dir}/${out_name}"
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
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${COMPILER:-}" != "clang" ]]; then
  echo "Skipping release packaging for compiler '${COMPILER:-unknown}'"
  exit 0
fi

CPACK_APPIMAGE_FLAG="ON"
if [[ "${DO_APPIMAGE}" -ne 1 ]]; then
  CPACK_APPIMAGE_FLAG="OFF"
fi

cmake -B "${BUILD_RELEASE_DIR}" --preset "${CLANG_RELEASE_PRESET}" -DCMAKE_LINK_WHAT_YOU_USE=FALSE -DCPACK_ENABLE_APPIMAGE=${CPACK_APPIMAGE_FLAG}
cmake --build "${BUILD_RELEASE_DIR}" --preset "${CLANG_RELEASE_PRESET}"
cmake --build "${BUILD_RELEASE_DIR}" --target package

if [[ "${DO_FLATPAK}" -eq 1 ]]; then
  [[ -n "${FLATPAK_OUT_DIR}" ]] || FLATPAK_OUT_DIR="${BUILD_RELEASE_DIR}"
  if ! ensure_flatpak_tools; then
    if [[ "${FLATPAK_EXPLICIT}" -eq 1 ]]; then
      echo "Flatpak requested but required tools are unavailable." >&2
      exit 1
    fi
    echo "Skipping Flatpak build (required tools are unavailable)." >&2
    echo "Install flatpak + flatpak-builder or run with --no-flatpak to suppress this warning." >&2
  else
    build_flatpak "${BUILD_RELEASE_DIR}" "${FLATPAK_OUT_DIR}"
  fi
fi

if [[ "${DO_CALLGRIND}" -eq 1 ]]; then
  if ! require_cmd valgrind; then
    echo "valgrind not found, skipping callgrind." >&2
    exit 0
  fi
  (
    cd "${BUILD_RELEASE_DIR}"
    ./bin/KataglyphisCppInference >/dev/null 2>&1 || true
    valgrind --tool=callgrind ./bin/KataglyphisCppInference
  )
fi
