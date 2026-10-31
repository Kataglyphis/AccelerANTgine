#!/usr/bin/env bash
# Investigate a documented process-local MIGraphX setting; this is not a release gate.
set -euo pipefail
if [[ $# -ne 5 ]]; then
  echo 'usage: diagnose-migraphx-detector.sh DEMO MODEL FIXTURE exhaustive|skip-rocblas|skip-no-mlir NEW_EVIDENCE_DIR' >&2
  exit 2
fi
demo=$(realpath -e "$1") model=$(realpath -e "$2") fixture=$(realpath -e "$3") mode=$4 evidence=$5
case "$mode" in
  exhaustive) setting=(ORT_MIGRAPHX_EXHAUSTIVE_TUNE=1) ;;
  skip-rocblas) setting=(MIGRAPHX_SKIP_BENCHMARKING=1 MIGRAPHX_SET_GEMM_PROVIDER=rocblas) ;;
  skip-no-mlir) setting=(MIGRAPHX_SKIP_BENCHMARKING=1 MIGRAPHX_DISABLE_MLIR=1) ;;
  *) echo 'Unsupported diagnostic mode' >&2; exit 2 ;;
esac
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
shared="$repo/third_party/ANTfrastructure/shared/python"
gpu_env="$repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
[[ -x "$demo" && -f "$model" && -f "$fixture" && -f "$shared/verify_ort_profile.py" && -f "$shared/compare_detector_parity.py" ]] || {
  echo 'Demo, model, fixture or shared helpers are missing' >&2; exit 1;
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
clean=(env -u LD_PRELOAD -u LD_AUDIT -u ORT_DYLIB_PATH -u ORT_LIB_LOCATION -u KATAGLYPHIS_ONNX_MODEL
  -u KATAGLYPHIS_ONNX_BACKEND -u KATAGLYPHIS_ORT_DEVICE -u GST_PLUGIN_PATH -u GST_PLUGIN_PATH_1_0
  -u GST_PLUGIN_SYSTEM_PATH -u GST_PLUGIN_SYSTEM_PATH_1_0 -u GST_PLUGIN_SCANNER -u GST_PLUGIN_SCANNER_1_0
  -u GST_REGISTRY -u GST_REGISTRY_1_0 -u GST_REGISTRY_FORK)
for selected in cpu migraphx; do
  extra=()
  [[ "$selected" != migraphx ]] || extra=("${setting[@]}")
  gpu_without_migraphx_overrides timeout --signal=TERM --kill-after=15s 240s "${clean[@]}" "${extra[@]}" \
    GST_REGISTRY_1_0="$evidence/$selected-gst-registry.bin" "$demo" --model "$model" --device "$selected" \
    --detector-image "$fixture" --detector-output "$evidence/$selected-1.json" \
    --detector-repeat-output "$evidence/$selected-2.json" --profile "$evidence/$selected-profile"
  shopt -s nullglob
  profiles=("$evidence/$selected-profile/"*.json)
  [[ ${#profiles[@]} -eq 1 ]] || { echo "Expected one $selected detector profile" >&2; exit 1; }
  python3 -I "$shared/verify_ort_profile.py" "${profiles[0]}" --device "$selected" --min-runs 2
done
cmp "$evidence/cpu-1.json" "$evidence/cpu-2.json"
status=0
for pair in 'cpu-1 migraphx-1' 'cpu-2 migraphx-2'; do
  read -r left right <<<"$pair"
  echo "Comparing $left with $right"
  if ! python3 -I "$shared/compare_detector_parity.py" "$evidence/$left.json" "$evidence/$right.json"; then status=1; fi
done
echo 'Comparing migraphx-1 with migraphx-2'
if ! python3 -I "$shared/compare_detector_parity.py" "$evidence/migraphx-1.json" "$evidence/migraphx-2.json" --pairwise; then status=1; fi
[[ $status -eq 0 ]] || exit "$status"
echo "Diagnostic $mode passed; this does not establish release verification"
