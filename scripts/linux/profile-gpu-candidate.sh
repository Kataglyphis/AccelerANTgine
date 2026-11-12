#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then echo 'usage: profile-gpu-candidate.sh ARTIFACT_DIR MODEL DEVICE' >&2; exit 2; fi
artifact_dir=$1 model=$2 device=$3
model="$(realpath -e "$model")"
case "$device" in cpu|cuda|migraphx) ;; *) echo 'Unsupported profile device' >&2; exit 2 ;; esac
# shellcheck source=lib/detector-evidence.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/detector-evidence.sh"
repo=$DETECTOR_EVIDENCE_REPO
detector_evidence_load_gpu_env
shopt -s nullglob
archives=("$artifact_dir"/*.tar.gz)
[[ ${#archives[@]} -eq 1 ]] || { echo 'Expected one candidate tarball' >&2; exit 1; }
appimages=("$artifact_dir"/*.AppImage)
[[ ${#appimages[@]} -eq 1 ]] || { echo 'Expected one candidate AppImage' >&2; exit 1; }
debs=("$artifact_dir"/*.deb)
[[ ${#debs[@]} -eq 1 ]] || { echo 'Expected one candidate DEB' >&2; exit 1; }
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/accelerantgine-profile.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
stage="$(realpath -e "$stage")"
mkdir "$stage/tar" "$stage/appimage" "$stage/deb"
tar -xzf "${archives[0]}" -C "$stage/tar"
dpkg-deb --extract "${debs[0]}" "$stage/deb"
cp -- "${appimages[0]}" "$stage/candidate.AppImage"
chmod u+x "$stage/candidate.AppImage"
(cd "$stage/appimage" && "$stage/candidate.AppImage" --appimage-extract >/dev/null)

run_demo() {
  local demo=$1 registry=$2
  shift 2
  (cd "$stage" && gpu_without_migraphx_overrides env -u LD_PRELOAD -u LD_AUDIT -u ORT_AMDGPU_EP_ROOT "${DETECTOR_EVIDENCE_GST_UNSET[@]}" \
    GST_REGISTRY_1_0="$registry" "$demo" "$@")
}

profile_package() {
  local root=$1 kind=$2 demo resolved
  local -a demos models
  mapfile -d '' -t demos < <(find "$root" -type f -path '*/usr/bin/AccelerANTgine_demo' -print0)
  [[ ${#demos[@]} -eq 1 && -x ${demos[0]} && ! -L ${demos[0]} ]] || {
    echo "Expected one executable ${kind} demo wrapper" >&2; return 1;
  }
  demo=${demos[0]}
  (detector_evidence_inside "$root" "$demo" "${kind} demo" >/dev/null)
  run_demo "$demo" "$stage/$kind-gst-registry.bin" --onnx-only --profile "$stage/$kind-ort-profile"
  detector_evidence_verify_profile "${kind} ORT" "$device" 0 "$stage/$kind"-ort-profile*.json
  run_demo "$demo" "$stage/$kind-gst-registry.bin" --video-check --model "$model" --device "$device" --profile "$stage/$kind-video-profile"
  detector_evidence_verify_profile "${kind} video inference ORT" "$device" 0 "$stage/$kind"-video-profile*.json
  if [[ "$device" != cpu ]]; then
    mapfile -d '' -t models < <(find "$root" -type f -path '*/share/accelerantgine/models/deim_dfine_n_coco.onnx' -print0)
    [[ ${#models[@]} -eq 1 && ! -L ${models[0]} ]] || { echo "Expected one ${kind} packaged model" >&2; return 1; }
    resolved="$(detector_evidence_inside "$root" "${models[0]}" "${kind} model")"
    bash "$repo/scripts/linux/check-gpu-detector-parity.sh" "$demo" "$resolved" "$device" "$stage/$kind-detector-parity"
  fi
}

profile_package "$stage/tar" tar
profile_package "$stage/appimage/squashfs-root" appimage
profile_package "$stage/deb" deb
