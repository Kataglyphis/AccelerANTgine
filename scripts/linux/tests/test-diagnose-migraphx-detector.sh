#!/usr/bin/env bash
# Exercise diagnostic settings, output comparisons and profile failures without a GPU.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
hub=${1:-"$repo/third_party/ANTfrastructure"}
work=$(mktemp -d "${TMPDIR:-/tmp}/accelerant-migraphx-diagnostic-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/repo/scripts/linux" "$work/repo/models" "$work/repo/third_party/ANTfrastructure/shared/python" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib"
cp "$hub/linux/scripts/lib/gpu-profile-env.sh" "$hub/linux/scripts/lib/log-bootstrap.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/"
cp "$repo/scripts/linux/diagnose-migraphx-detector.sh" "$work/repo/scripts/linux/"
cp "$hub/shared/python/verify_ort_profile.py" "$hub/shared/python/compare_detector_parity.py" "$work/repo/third_party/ANTfrastructure/shared/python/"
fixture="$repo/third_party/ModelANT/contracts/fixtures/two_cats.jpg"
printf 'test model\n' >"$work/model.onnx"
printf '%s  deim_dfine_n_coco.onnx\n' "$(sha256sum "$work/model.onnx" | cut -d ' ' -f 1)" >"$work/repo/models/models.lock"
cat >"$work/demo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
[[ -z ${MIGRAPHX_UNKNOWN+x} ]]
provider=CPUExecutionProvider
if [[ "$device" == cpu ]]; then
  [[ -z ${MIGRAPHX_SKIP_BENCHMARKING+x} && -z ${ORT_MIGRAPHX_EXHAUSTIVE_TUNE+x} ]]
else
  provider=MIGraphXExecutionProvider
  case "$EXPECT_MODE" in
    exhaustive) [[ ${ORT_MIGRAPHX_EXHAUSTIVE_TUNE:-} == 1 && -z ${MIGRAPHX_SKIP_BENCHMARKING+x} ]] ;;
    skip-rocblas) [[ ${MIGRAPHX_SKIP_BENCHMARKING:-} == 1 && ${MIGRAPHX_SET_GEMM_PROVIDER:-} == rocblas ]] ;;
    skip-no-mlir) [[ ${MIGRAPHX_SKIP_BENCHMARKING:-} == 1 && ${MIGRAPHX_DISABLE_MLIR:-} == 1 ]] ;;
    *) exit 1 ;;
  esac
fi
score=0.9
second_score=0.8
if [[ ${EDGE_PARITY:-0} == 1 ]]; then
  score=0.80
  [[ "$device" == cpu ]] || score=0.76
  second_score=0.78
fi
printf '{"schema_version":1,"width":480,"height":659,"detections":[{"class":15,"score":%s,"box":[0,250,450,640]},{"class":15,"score":%s,"box":[0,0,250,200]}]}\n' "$score" "$second_score" >"$output"
cp "$output" "$repeat"
if [[ ${BAD_REPEAT:-0} == 1 && "$device" != cpu ]]; then
  printf '{"schema_version":1,"width":480,"height":659,"detections":[{"class":15,"score":0.3,"box":[0,250,450,640]}]}\n' >"$repeat"
fi
provider2=$provider
[[ ${BAD_SECOND_PROFILE:-0} != 1 || "$device" == cpu ]] || provider2=CPUExecutionProvider
mkdir "$profile"
printf '[{"cat":"Session","name":"model_run","ph":"X","pid":42,"ts":0,"dur":10},{"cat":"Node","ph":"X","pid":42,"ts":1,"dur":1,"args":{"provider":"%s","op_name":"Conv"}},{"cat":"Session","name":"model_run","ph":"X","pid":42,"ts":20,"dur":10},{"cat":"Node","ph":"X","pid":42,"ts":21,"dur":1,"args":{"provider":"%s","op_name":"Conv"}}]\n' "$provider" "$provider2" >"$profile/ort.json"
EOF
chmod +x "$work/demo"
check="$work/repo/scripts/linux/diagnose-migraphx-detector.sh"
shared="$work/repo/third_party/ANTfrastructure/shared/python"
sed 's/--pairwise/--legacy-pairwise/g' "$hub/shared/python/compare_detector_parity.py" >"$shared/compare_detector_parity.py"
if EXPECT_MODE=skip-rocblas bash "$check" "$work/demo" "$work/model.onnx" "$fixture" skip-rocblas "$work/legacy" >/dev/null 2>&1; then
  echo 'A comparator without pairwise support was accepted' >&2; exit 1
fi
[[ ! -e "$work/legacy" ]] || { echo 'Old comparator was checked too late' >&2; exit 1; }
cp "$hub/shared/python/compare_detector_parity.py" "$shared/compare_detector_parity.py"
mv "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh" "$work/gpu-profile-env.sh"
if EXPECT_MODE=exhaustive bash "$check" "$work/demo" "$work/model.onnx" "$fixture" exhaustive "$work/missing-env" >/dev/null 2>&1; then
  echo 'Missing GPU environment helper was accepted' >&2; exit 1
fi
[[ ! -e "$work/missing-env" ]] || { echo 'Missing helper was checked too late' >&2; exit 1; }
mv "$work/gpu-profile-env.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
mv "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh" "$work/log-bootstrap.sh"
if EXPECT_MODE=exhaustive bash "$check" "$work/demo" "$work/model.onnx" "$fixture" exhaustive "$work/missing-bootstrap" >/dev/null 2>&1; then
  echo 'Missing GPU environment logging bootstrap was accepted' >&2; exit 1
fi
[[ ! -e "$work/missing-bootstrap" ]] || { echo 'Missing bootstrap was checked too late' >&2; exit 1; }
mv "$work/log-bootstrap.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh"
for mode in exhaustive skip-rocblas skip-no-mlir; do
  EXPECT_MODE="$mode" MIGRAPHX_SKIP_BENCHMARKING=poison ORT_MIGRAPHX_EXHAUSTIVE_TUNE=poison MIGRAPHX_UNKNOWN=poison \
    bash "$check" "$work/demo" "$work/model.onnx" "$fixture" "$mode" "$work/$mode"
done
EXPECT_MODE=skip-rocblas EDGE_PARITY=1 bash "$check" "$work/demo" "$work/model.onnx" "$fixture" skip-rocblas "$work/edge"
sed 's/ --pairwise; then/; then/' "$check" >"$work/repo/scripts/linux/without-pairwise.sh"
if EXPECT_MODE=skip-rocblas EDGE_PARITY=1 bash "$work/repo/scripts/linux/without-pairwise.sh" "$work/demo" "$work/model.onnx" "$fixture" skip-rocblas "$work/mutant" >"$work/mutant.log" 2>&1; then
  echo 'GPU repeat wrongly accepted with the CPU-only oracle' >&2; exit 1
fi
grep -Fq 'CPU baseline did not detect both expected cats' "$work/mutant.log" || { cat "$work/mutant.log" >&2; exit 1; }
for fault in BAD_REPEAT BAD_SECOND_PROFILE; do
  if env "$fault=1" EXPECT_MODE=skip-rocblas bash "$check" "$work/demo" "$work/model.onnx" \
    "$fixture" skip-rocblas "$work/$fault" >/dev/null 2>&1; then
    echo "$fault was accepted" >&2; exit 1
  fi
done
printf 'tampered\n' >>"$work/model.onnx"
if EXPECT_MODE=exhaustive bash "$check" "$work/demo" "$work/model.onnx" "$fixture" exhaustive "$work/invalid" >/dev/null 2>&1; then
  echo 'Changed model was accepted' >&2; exit 1
fi
echo 'MIGraphX diagnostic settings and failure checks passed'
