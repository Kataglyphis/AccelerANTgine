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
APPIMAGE_OUT_DIR=""
FLATPAK_OUT_DIR=""
FLATPAK_RUNTIME="org.freedesktop.Platform"
FLATPAK_RUNTIME_VERSION="24.08"
FLATPAK_SDK="org.freedesktop.Sdk"
FLATPAK_BRANCH="master"
AUTO_INSTALL_FLATPAK="1"
APPIMAGETOOL_CMD=""
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
  --appimage-out-dir <dir>      AppImage output directory (default: build dir)
  --flatpak|--flatpack          Build Flatpak bundle (default: on)
  --no-flatpak|--no-flatpack    Disable Flatpak build
  --flatpak-out-dir <dir>       Flatpak output directory (default: build dir)
  --flatpak-runtime <name>      Flatpak runtime (default: org.freedesktop.Platform)
  --flatpak-runtime-version <v> Flatpak runtime version (default: 24.08)
  --flatpak-sdk <name>          Flatpak SDK (default: org.freedesktop.Sdk)
  --flatpak-branch <name>       Flatpak branch (default: master)
  --flatpak-arch <name>         Flatpak arch override (default: auto-detect)
  --auto-install-flatpak <0|1>  Auto-install flatpak tools (default: 1)
  --appimagetool-cmd <cmd>      Explicit appimagetool command/path
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

ensure_appimagetool() {
  if [[ -n "${APPIMAGETOOL_CMD}" ]]; then
    if require_cmd "${APPIMAGETOOL_CMD}"; then
      echo "${APPIMAGETOOL_CMD}"
      return 0
    fi
    return 1
  fi

  if command -v appimagetool >/dev/null 2>&1; then
    echo "appimagetool"
    return 0
  fi

  local arch
  arch="$(normalize_arch)"

  local appimagetool_name=""
  case "${arch}" in
    x86_64) appimagetool_name="appimagetool-x86_64.AppImage" ;;
    aarch64) appimagetool_name="appimagetool-aarch64.AppImage" ;;
    *)
      echo "Unsupported architecture for automatic appimagetool download: ${arch}" >&2
      return 1
      ;;
  esac

  local wrapper_path="${BUILD_RELEASE_DIR}/tools/appimagetool-wrapper.sh"
  if [[ -x "${wrapper_path}" ]]; then
    echo "${wrapper_path}"
    return 0
  fi

  local cpack_local_tool="${BUILD_RELEASE_DIR}/tools/${appimagetool_name}"
  if [[ -x "${cpack_local_tool}" ]]; then
    echo "${cpack_local_tool}"
    return 0
  fi

  local local_path="${BUILD_RELEASE_DIR}/tools/${appimagetool_name}"
  mkdir -p "$(dirname "${local_path}")"
  if [[ ! -x "${local_path}" ]]; then
    if ! require_cmd wget; then
      run_privileged_cmd apt-get update
      run_privileged_cmd apt-get install -y wget
    fi
    wget -O "${local_path}" "https://github.com/AppImage/AppImageKit/releases/download/continuous/${appimagetool_name}"
    chmod +x "${local_path}"
  fi

  echo "${local_path}"
}

ensure_appimage_tools() {
  if require_cmd mksquashfs; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    run_privileged_cmd apt-get update
    run_privileged_cmd apt-get install -y squashfs-tools
  fi
  require_cmd mksquashfs
}

sanitize_for_app_id() {
  local value="$1"
  value="${value,,}"
  value="${value//[^a-zA-Z0-9]/-}"
  value="${value#-}"
  value="${value%-}"
  if [[ -z "${value}" ]]; then
    value="kataglyphiscppproject"
  fi
  echo "${value}"
}

has_cpack_appimage() {
  local build_dir="$1"
  compgen -G "${build_dir}/*.AppImage" >/dev/null 2>&1
}

build_appimage() {
  local build_dir="$1"
  local out_dir="$2"
  local appimagetool
  appimagetool="$(ensure_appimagetool)"
  ensure_appimage_tools

  local cache_file="${build_dir}/CMakeCache.txt"
  local project_name="KataglyphisCppProject"
  local project_version=""
  if [[ -f "${cache_file}" ]]; then
    project_name="$(read_cache_var "${cache_file}" CMAKE_PROJECT_NAME || true)"
    project_version="$(read_cache_var "${cache_file}" CMAKE_PROJECT_VERSION || true)"
  fi
  [[ -n "${project_name}" ]] || project_name="KataglyphisCppProject"

  local arch="$(normalize_arch)"
  local git_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  local version_suffix="${project_version:-${git_sha:-unknown}}"

  local appdir="${build_dir}/AppDir"
  rm -rf "${appdir}"
  mkdir -p "${appdir}"

  cmake --install "${build_dir}" --prefix "${appdir}/usr"

  local runtime_exec=""
  if [[ -x "${appdir}/usr/bin/${project_name}" ]]; then
    runtime_exec="${project_name}"
  elif [[ -d "${appdir}/usr/bin" ]]; then
    runtime_exec="$(find "${appdir}/usr/bin" -maxdepth 1 -type f -executable | head -n 1 | xargs -r basename)"
  fi

  if [[ -z "${runtime_exec}" ]]; then
    echo "No executable found under ${appdir}/usr/bin; skipping AppImage build." >&2
    return 0
  fi

  cat >"${appdir}/AppRun" <<EOF
#!/usr/bin/env bash
set -euo pipefail
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\${HERE}/usr/bin/${project_name}" "\$@"
EOF
  sed -i "s|/usr/bin/${project_name}|/usr/bin/${runtime_exec}|g" "${appdir}/AppRun"
  chmod +x "${appdir}/AppRun"

  cat >"${appdir}/${project_name}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${project_name}
Exec=${project_name}
Icon=${project_name}
Categories=Utility;
Terminal=true
EOF
  sed -i "s|Exec=${project_name}|Exec=${runtime_exec}|g" "${appdir}/${project_name}.desktop"

  if [[ -f "${WORKSPACE_DIR}/images/logo.png" ]]; then
    cp "${WORKSPACE_DIR}/images/logo.png" "${appdir}/${project_name}.png"
  elif [[ -f "${WORKSPACE_DIR}/images/Engine_logo.png" ]]; then
    cp "${WORKSPACE_DIR}/images/Engine_logo.png" "${appdir}/${project_name}.png"
  fi

  mkdir -p "${out_dir}"
  local out_name="${project_name}-${version_suffix}-linux-${arch}.AppImage"

  local -a appimagetool_cmd
  if [[ "${appimagetool}" == *.AppImage ]]; then
    appimagetool_cmd=("${appimagetool}" --appimage-extract-and-run)
  else
    appimagetool_cmd=("${appimagetool}")
  fi

  ARCH="${arch}" "${appimagetool_cmd[@]}" "${appdir}" "${out_dir}/${out_name}"
  echo "AppImage written: ${out_dir}/${out_name}"
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

  local cache_file="${build_dir}/CMakeCache.txt"
  local project_name="KataglyphisCppProject"
  local project_version=""
  if [[ -f "${cache_file}" ]]; then
    project_name="$(read_cache_var "${cache_file}" CMAKE_PROJECT_NAME || true)"
    project_version="$(read_cache_var "${cache_file}" CMAKE_PROJECT_VERSION || true)"
  fi
  [[ -n "${project_name}" ]] || project_name="KataglyphisCppProject"

  local git_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  local version_suffix="${project_version:-${git_sha:-unknown}}"

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
  local desktop_source=""
  if [[ -f "${desktop_dir}/${project_name}.desktop" ]]; then
    desktop_source="${desktop_dir}/${project_name}.desktop"
  elif [[ -f "${desktop_dir}/${app_id}.desktop" ]]; then
    desktop_source="${desktop_dir}/${app_id}.desktop"
  fi
  if [[ -n "${desktop_source}" ]]; then
    if [[ "${desktop_source}" != "${desktop_dir}/${app_id}.desktop" ]]; then
      cp -f "${desktop_source}" "${desktop_dir}/${app_id}.desktop"
    fi
    if [[ "${desktop_source}" != "${desktop_dir}/${app_id}.desktop" ]]; then
      rm -f "${desktop_source}"
    fi
  fi
  if [[ -f "${icon_dir}/${project_name}.png" ]]; then
    cp -f "${icon_dir}/${project_name}.png" "${icon_dir}/${app_id}.png"
    rm -f "${icon_dir}/${project_name}.png"
  fi
  local metainfo_source=""
  if [[ -f "${metainfo_dir}/${project_name}.appdata.xml" ]]; then
    metainfo_source="${metainfo_dir}/${project_name}.appdata.xml"
  elif [[ -f "${metainfo_dir}/${app_id}.appdata.xml" ]]; then
    metainfo_source="${metainfo_dir}/${app_id}.appdata.xml"
  fi
  if [[ -n "${metainfo_source}" ]]; then
    if [[ "${metainfo_source}" != "${metainfo_dir}/${app_id}.appdata.xml" ]]; then
      cp -f "${metainfo_source}" "${metainfo_dir}/${app_id}.appdata.xml"
    fi
    if [[ "${metainfo_source}" != "${metainfo_dir}/${app_id}.appdata.xml" ]]; then
      rm -f "${metainfo_source}"
    fi
  fi

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
    --appimagetool-cmd)
      APPIMAGETOOL_CMD="$2"
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
    --appimage-out-dir)
      APPIMAGE_OUT_DIR="$2"
      shift 2
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

cmake -B "${BUILD_RELEASE_DIR}" --preset "${CLANG_RELEASE_PRESET}"
cmake --build "${BUILD_RELEASE_DIR}" --preset "${CLANG_RELEASE_PRESET}"
cmake --build "${BUILD_RELEASE_DIR}" --target package

if [[ "${DO_APPIMAGE}" -eq 1 ]]; then
  if has_cpack_appimage "${BUILD_RELEASE_DIR}"; then
    echo "CPack AppImage already exists in ${BUILD_RELEASE_DIR}; skipping extra AppImage build."
  else
    [[ -n "${APPIMAGE_OUT_DIR}" ]] || APPIMAGE_OUT_DIR="${BUILD_RELEASE_DIR}"
    build_appimage "${BUILD_RELEASE_DIR}" "${APPIMAGE_OUT_DIR}"
  fi
fi

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
