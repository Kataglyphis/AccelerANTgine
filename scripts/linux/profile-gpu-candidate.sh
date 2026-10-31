#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then echo 'usage: profile-gpu-candidate.sh ARTIFACT_DIR MODEL DEVICE' >&2; exit 2; fi
artifact_dir=$1 model=$2 device=$3
case "$device" in cpu|cuda|migraphx) ;; *) echo 'Unsupported profile device' >&2; exit 2 ;; esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shopt -s nullglob
archives=("$artifact_dir"/*.tar.gz)
[[ ${#archives[@]} -eq 1 ]] || { echo 'Expected one candidate tarball' >&2; exit 1; }
appimages=("$artifact_dir"/*.AppImage)
[[ ${#appimages[@]} -eq 1 ]] || { echo 'Expected one candidate AppImage' >&2; exit 1; }
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/accelerantgine-profile.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
stage="$(realpath -e "$stage")"
mkdir "$stage/tar" "$stage/appimage"
tar -xzf "${archives[0]}" -C "$stage/tar"
cp -- "${appimages[0]}" "$stage/candidate.AppImage"
chmod u+x "$stage/candidate.AppImage"
(cd "$stage/appimage" && "$stage/candidate.AppImage" --appimage-extract >/dev/null)

run_demo() {
  local demo=$1 registry=$2
  shift 2
  env -u LD_PRELOAD -u LD_AUDIT -u GST_PLUGIN_PATH -u GST_PLUGIN_PATH_1_0 -u GST_PLUGIN_SYSTEM_PATH \
    -u GST_PLUGIN_SYSTEM_PATH_1_0 -u GST_PLUGIN_SCANNER -u GST_PLUGIN_SCANNER_1_0 \
    -u GST_REGISTRY -u GST_REGISTRY_1_0 -u GST_REGISTRY_FORK \
    GST_REGISTRY_1_0="$registry" "$demo" "$@"
}

profile_package() {
  local root=$1 kind=$2 demo resolved
  local -a demos profiles
  mapfile -d '' -t demos < <(find "$root" -type f -path '*/usr/bin/AccelerANTgine_demo' -print0)
  [[ ${#demos[@]} -eq 1 && -x ${demos[0]} && ! -L ${demos[0]} ]] || {
    echo "Expected one executable ${kind} demo wrapper" >&2; return 1;
  }
  demo=${demos[0]}
  resolved="$(realpath -e "$demo")"
  case "$resolved" in "$root"/*) ;; *) echo "${kind} demo escapes its package" >&2; return 1 ;; esac
  run_demo "$demo" "$stage/$kind-gst-registry.bin" --onnx-only --model "$model" --profile "$stage/$kind-ort-profile"
  profiles=("$stage/$kind"-ort-profile*.json)
  [[ ${#profiles[@]} -eq 1 ]] || { echo "Expected one ${kind} ORT profile" >&2; return 1; }
  python3 -I "$repo/third_party/ANTfrastructure/shared/python/verify_ort_profile.py" "${profiles[0]}" --device "$device"
  run_demo "$demo" "$stage/$kind-gst-registry.bin" --video-check --model "$model" --device "$device" --profile "$stage/$kind-video-profile"
  profiles=("$stage/$kind"-video-profile*.json)
  [[ ${#profiles[@]} -eq 1 ]] || { echo "Expected one ${kind} video inference ORT profile" >&2; return 1; }
  python3 -I "$repo/third_party/ANTfrastructure/shared/python/verify_ort_profile.py" "${profiles[0]}" --device "$device"
}

profile_package "$stage/tar" tar
profile_package "$stage/appimage/squashfs-root" appimage
