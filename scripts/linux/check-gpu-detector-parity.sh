#!/usr/bin/env bash
# Verify CPU and accelerated (GPU, XNNPACK or DNNL) detector results and profiles on the pinned ModelANT image.
set -euo pipefail
if [[ $# -ne 4 ]]; then echo 'usage: check-gpu-detector-parity.sh DEMO MODEL cuda|migraphx|xnnpack|dnnl NEW_EVIDENCE_DIR' >&2; exit 2; fi
demo=$(realpath -e "$1") model=$(realpath -e "$2") device=$3 evidence=$4
case "$device" in cuda|migraphx|xnnpack|dnnl) ;; *) echo 'Unsupported accelerated device' >&2; exit 2 ;; esac
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture="$repo/third_party/ModelANT/contracts/fixtures/two_cats.jpg"
shared="$repo/third_party/ANTfrastructure/shared/python"
gpu_env="$repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
[[ -x "$demo" && -f "$model" && -f "$fixture" && -f "$shared/verify_ort_profile.py" && -f "$shared/compare_detector_parity.py" ]] || {
  echo 'Demo, locked model, fixture or shared parity helpers are missing' >&2; exit 1;
}
[[ -f "$gpu_env" ]] || { echo 'Pinned ANTfrastructure lacks GPU profile environment isolation' >&2; exit 1; }
# shellcheck source=/dev/null
source "$gpu_env"
declare -F gpu_without_migraphx_overrides >/dev/null || { echo 'Pinned GPU environment helper lacks its API' >&2; exit 1; }
parity_help=$(python3 -I "$shared/compare_detector_parity.py" --help)
profile_help=$(python3 -I "$shared/verify_ort_profile.py" --help)
[[ "$parity_help" == *--pairwise* && "$profile_help" == *--min-runs* ]] || {
  echo 'Pinned shared helpers lack pairwise or per-run verification' >&2; exit 1;
}
mapfile -t locked_hashes < <(awk '$2 == "deim_dfine_n_coco.onnx" {print $1}' "$repo/models/models.lock")
[[ ${#locked_hashes[@]} -eq 1 && ${locked_hashes[0]} =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid model lock' >&2; exit 1; }
printf '%s  %s\n' "${locked_hashes[0]}" "$model" | sha256sum -c -
printf '%s  %s\n' '6d375ac20fadfd400b3033084f8b0581dcc145f7c14e3b24b97975e379c52999' "$fixture" | sha256sum -c -
mkdir -- "$evidence"
evidence=$(realpath -e "$evidence")
fixture=$(realpath -e "$fixture")
for run in cpu gpu; do
  selected=$device
  [[ "$run" != cpu ]] || selected=cpu
  output="$evidence/cpu1.json"
  repeat=(--detector-repeat-output "$evidence/cpu2.json")
  if [[ "$run" == gpu ]]; then
    output="$evidence/gpu1.json"
    repeat=(--detector-repeat-output "$evidence/gpu2.json")
  fi
  clean=(env -u LD_PRELOAD -u LD_AUDIT -u ORT_DYLIB_PATH -u ORT_LIB_LOCATION -u KATAGLYPHIS_ONNX_MODEL
    -u KATAGLYPHIS_ONNX_BACKEND -u KATAGLYPHIS_ORT_DEVICE -u GST_PLUGIN_PATH -u GST_PLUGIN_PATH_1_0
    -u GST_PLUGIN_SYSTEM_PATH -u GST_PLUGIN_SYSTEM_PATH_1_0 -u GST_PLUGIN_SCANNER -u GST_PLUGIN_SCANNER_1_0
    -u GST_REGISTRY -u GST_REGISTRY_1_0 -u GST_REGISTRY_FORK)
  # A GPU's CPU leg proves the package alone; a CPU provider compares with CPU in the same environment.
  if [[ "$selected" == cpu && "$device" != xnnpack && "$device" != dnnl ]]; then clean+=(-u LD_LIBRARY_PATH); fi
  gpu_without_migraphx_overrides "${clean[@]}" GST_REGISTRY_1_0="$evidence/$run-gst-registry.bin" "$demo" --model "$model" --device "$selected" \
    --detector-image "$fixture" --detector-output "$output" "${repeat[@]}" --profile "$evidence/$run-profile"
  shopt -s nullglob
  profiles=("$evidence/$run-profile/"*.json)
  [[ ${#profiles[@]} -eq 1 ]] || { echo "Expected one $run detector profile" >&2; exit 1; }
  python3 -I "$shared/verify_ort_profile.py" "${profiles[0]}" --device "$selected" --min-runs 2
done
python3 -I "$shared/compare_detector_parity.py" "$evidence/cpu1.json" "$evidence/cpu2.json"
python3 -I "$shared/compare_detector_parity.py" "$evidence/cpu1.json" "$evidence/gpu1.json"
python3 -I "$shared/compare_detector_parity.py" "$evidence/cpu1.json" "$evidence/gpu2.json"
python3 -I "$shared/compare_detector_parity.py" "$evidence/gpu1.json" "$evidence/gpu2.json" --pairwise
echo "Detector parity evidence: $evidence"
