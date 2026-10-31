#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
hub=${1:-"$repo/third_party/ANTfrastructure"}
work=$(mktemp -d "${TMPDIR:-/tmp}/accelerant-parity-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
fixture="$repo/third_party/ModelANT/contracts/fixtures/two_cats.jpg"
mkdir -p "$work/repo/scripts/linux" "$work/repo/models" "$work/repo/third_party/ModelANT/contracts/fixtures" \
  "$work/repo/third_party/ANTfrastructure/shared/python" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib"
cp "$hub/linux/scripts/lib/gpu-profile-env.sh" "$hub/linux/scripts/lib/log-bootstrap.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/"
cp "$repo/scripts/linux/check-gpu-detector-parity.sh" "$work/repo/scripts/linux/"
cp "$fixture" "$work/repo/third_party/ModelANT/contracts/fixtures/"
printf 'test model\n' >"$work/model.onnx"
printf '%s  deim_dfine_n_coco.onnx\n' "$(sha256sum "$work/model.onnx" | cut -d ' ' -f 1)" >"$work/repo/models/models.lock"
check="$work/repo/scripts/linux/check-gpu-detector-parity.sh"
if bash "$check" /bin/true "$work/model.onnx" cuda "$work/missing" >/dev/null 2>&1; then
  echo 'Missing shared helpers were accepted' >&2; exit 1
fi
cp "$hub/shared/python/verify_ort_profile.py" "$hub/shared/python/compare_detector_parity.py" \
  "$work/repo/third_party/ANTfrastructure/shared/python/"
shared="$work/repo/third_party/ANTfrastructure/shared/python"
sed 's/--pairwise/--legacy-pairwise/g' "$hub/shared/python/compare_detector_parity.py" >"$shared/compare_detector_parity.py"
if bash "$check" /bin/true "$work/model.onnx" cuda "$work/legacy-pairwise" >/dev/null 2>&1; then
  echo 'A comparator without pairwise support was accepted' >&2; exit 1
fi
[[ ! -e "$work/legacy-pairwise" ]] || { echo 'Old comparator was checked too late' >&2; exit 1; }
cp "$hub/shared/python/compare_detector_parity.py" "$shared/compare_detector_parity.py"
sed 's/--min-runs/--legacy-runs/g' "$hub/shared/python/verify_ort_profile.py" >"$shared/verify_ort_profile.py"
if bash "$check" /bin/true "$work/model.onnx" cuda "$work/legacy-profile" >/dev/null 2>&1; then
  echo 'A profiler without per-run support was accepted' >&2; exit 1
fi
[[ ! -e "$work/legacy-profile" ]] || { echo 'Old profiler was checked too late' >&2; exit 1; }
cp "$hub/shared/python/verify_ort_profile.py" "$shared/verify_ort_profile.py"
cat >"$work/demo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${MIGRAPHX_SKIP_BENCHMARKING+x} && -z ${ORT_MIGRAPHX_MODEL_CACHE_PATH+x} && -z ${MIGRAPHX_UNKNOWN+x} ]]
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model|--detector-image) shift 2 ;;
    --device) device=$2; shift 2 ;;
    --detector-output) output=$2; shift 2 ;;
    --detector-repeat-output) repeat=$2; shift 2 ;;
    --profile) profile=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
provider=CUDAExecutionProvider
[[ "$device" != cpu ]] || provider=CPUExecutionProvider
[[ ${BAD_GPU_PROFILE:-0} != 1 || "$device" == cpu ]] || provider=CPUExecutionProvider
score=0.90
[[ ${BAD_GPU_OUTPUT:-0} != 1 || "$device" == cpu ]] || score=0.30
second_score=0.8
if [[ ${EDGE_PARITY:-0} == 1 ]]; then
  score=0.80
  [[ "$device" == cpu ]] || score=0.76
  second_score=0.78
fi
printf '{"schema_version":1,"width":480,"height":659,"detections":[{"class":15,"score":%s,"box":[0,250,450,640]},{"class":15,"score":%s,"box":[0,0,250,200]}]}\n' "$score" "$second_score" >"$output"
if [[ -n ${repeat:-} ]]; then
  if [[ ( ${BAD_GPU_REPEAT:-0} == 1 && "$device" != cpu ) || ( ${BAD_CPU_REPEAT:-0} == 1 && "$device" == cpu ) ]]; then
    printf '{"schema_version":1,"width":480,"height":659,"detections":[{"class":15,"score":0.3,"box":[0,250,450,640]}]}\n' >"$repeat"
  elif [[ ${MISSING_CPU_REPEAT:-0} == 1 && "$device" == cpu ]]; then
    :
  else
    cp "$output" "$repeat"
  fi
fi
mkdir "$profile"
provider2=$provider
[[ ${BAD_GPU_SECOND_PROFILE:-0} != 1 || "$device" == cpu ]] || provider2=CPUExecutionProvider
[[ ${BAD_CPU_SECOND_PROFILE:-0} != 1 || "$device" != cpu ]] || provider2=CUDAExecutionProvider
printf '[{"cat":"Session","name":"model_run","ph":"X","pid":42,"ts":0,"dur":10},{"cat":"Node","ph":"X","pid":42,"ts":1,"dur":1,"args":{"provider":"%s","op_name":"Conv"}},{"cat":"Session","name":"model_run","ph":"X","pid":42,"ts":20,"dur":10},{"cat":"Node","ph":"X","pid":42,"ts":21,"dur":1,"args":{"provider":"%s","op_name":"Conv"}}]\n' "$provider" "$provider2" >"$profile/ort.json"
EOF
chmod +x "$work/demo"
mv "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh" "$work/gpu-profile-env.sh"
if bash "$check" "$work/demo" "$work/model.onnx" cuda "$work/missing-env" >/dev/null 2>&1; then
  echo 'Missing GPU environment helper was accepted' >&2; exit 1
fi
[[ ! -e "$work/missing-env" ]] || { echo 'Missing helper was checked too late' >&2; exit 1; }
mv "$work/gpu-profile-env.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
mv "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh" "$work/log-bootstrap.sh"
if bash "$check" "$work/demo" "$work/model.onnx" cuda "$work/missing-bootstrap" >/dev/null 2>&1; then
  echo 'Missing GPU environment logging bootstrap was accepted' >&2; exit 1
fi
[[ ! -e "$work/missing-bootstrap" ]] || { echo 'Missing bootstrap was checked too late' >&2; exit 1; }
mv "$work/log-bootstrap.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh"
MIGRAPHX_SKIP_BENCHMARKING=1 ORT_MIGRAPHX_MODEL_CACHE_PATH=/tmp MIGRAPHX_UNKNOWN=poison bash "$check" "$work/demo" "$work/model.onnx" cuda "$work/pass"
EDGE_PARITY=1 bash "$check" "$work/demo" "$work/model.onnx" cuda "$work/edge"
for fault in BAD_GPU_PROFILE BAD_GPU_OUTPUT BAD_GPU_REPEAT BAD_GPU_SECOND_PROFILE BAD_CPU_REPEAT MISSING_CPU_REPEAT BAD_CPU_SECOND_PROFILE; do
  if env "$fault=1" bash "$check" "$work/demo" "$work/model.onnx" cuda "$work/$fault" >/dev/null 2>&1; then
    echo "$fault was accepted" >&2; exit 1
  fi
done
sed 's/ --pairwise$//' "$check" >"$work/repo/scripts/linux/without-pairwise.sh"
if EDGE_PARITY=1 bash "$work/repo/scripts/linux/without-pairwise.sh" "$work/demo" "$work/model.onnx" cuda "$work/mutant" >"$work/mutant.log" 2>&1; then
  echo 'GPU repeat wrongly accepted with the CPU-only oracle' >&2; exit 1
fi
grep -Fq 'CPU baseline did not detect both expected cats' "$work/mutant.log" || { cat "$work/mutant.log" >&2; exit 1; }
printf 'altered\n' >>"$work/model.onnx"
if bash "$check" "$work/demo" "$work/model.onnx" cuda "$work/invalid-model" >/dev/null 2>&1; then
  echo 'Changed model was accepted' >&2; exit 1
fi
echo 'Detector parity orchestration checks passed'
