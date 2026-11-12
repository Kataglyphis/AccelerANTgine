#!/usr/bin/env bash
# Exercises the parity gate's orchestration and failure verdicts over a synthetic demo; no GPU runs.
set -euo pipefail
# shellcheck source=detector-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/detector-fixture.sh"
detector_fixture_tree check-gpu-detector-parity.sh "$@"
mkdir -p "$DETECTOR_REPO/third_party/ModelANT/contracts/fixtures"
cp "$DETECTOR_FIXTURE" "$DETECTOR_REPO/third_party/ModelANT/contracts/fixtures/"
# Usage: run_check EVIDENCE [DEMO] [DEVICE]; the suite's usual gate call.
run_check() { bash "$DETECTOR_CHECK" "${2:-/bin/true}" "$SUITE_WORK/model.onnx" "${3:-cuda}" "$1"; }
run_demo() { run_check "$1" "$SUITE_WORK/demo" "${2:-cuda}"; }
suite_refuses 'Missing shared helpers were accepted' run_check "$SUITE_WORK/missing"
detector_fixture_shared_helpers
detector_fixture_legacy_tool compare_detector_parity.py --pairwise 'A comparator without pairwise support was accepted' \
  'Old comparator was checked too late' run_check "$SUITE_WORK/legacy-pairwise"
detector_fixture_legacy_tool verify_ort_profile.py --min-runs 'A profiler without per-run support was accepted' \
  'Old profiler was checked too late' run_check "$SUITE_WORK/legacy-profile"
detector_fixture_demo <<'POLICY'
[[ -z ${MIGRAPHX_SKIP_BENCHMARKING+x} && -z ${ORT_MIGRAPHX_MODEL_CACHE_PATH+x} && -z ${MIGRAPHX_UNKNOWN+x} ]]
[[ -z ${ORT_AMDGPU_EP_ROOT+x} ]]
[[ ${NEEDS_LIBRARY_PATH:-0} != 1 || -n ${LD_LIBRARY_PATH+x} ]]
provider=CUDAExecutionProvider
[[ "$device" != cpu ]] || provider=CPUExecutionProvider
[[ "$device" != xnnpack ]] || provider=XnnpackExecutionProvider
[[ ${BAD_GPU_PROFILE:-0} != 1 || "$device" == cpu ]] || provider=CPUExecutionProvider
[[ ${BAD_GPU_OUTPUT:-0} != 1 || "$device" == cpu ]] || score=0.30
if [[ ( ${BAD_GPU_REPEAT:-0} == 1 && "$device" != cpu ) || ( ${BAD_CPU_REPEAT:-0} == 1 && "$device" == cpu ) ]]; then repeat_fault=bad; fi
[[ ${MISSING_CPU_REPEAT:-0} != 1 || "$device" != cpu ]] || repeat_fault=missing
[[ ${BAD_CPU_SECOND_PROFILE:-0} != 1 || "$device" != cpu ]] || provider2=CUDAExecutionProvider
POLICY
detector_fixture_missing_hub_files run_demo
MIGRAPHX_SKIP_BENCHMARKING=1 ORT_MIGRAPHX_MODEL_CACHE_PATH=/tmp MIGRAPHX_UNKNOWN=poison ORT_AMDGPU_EP_ROOT=/image run_demo "$SUITE_WORK/pass"
EDGE_PARITY=1 run_demo "$SUITE_WORK/edge"
NEEDS_LIBRARY_PATH=1 LD_LIBRARY_PATH=/opt/gcc/lib64 run_demo "$SUITE_WORK/xnnpack" xnnpack
NEEDS_LIBRARY_PATH=1 LD_LIBRARY_PATH=/opt/gcc/lib64 suite_refuses "A GPU check's CPU leg kept the caller's LD_LIBRARY_PATH" run_demo "$SUITE_WORK/gpu-cpu-leg"
BAD_GPU_PROFILE=1 suite_refuses 'An XNNPACK request profiled on plain CPU was accepted' run_demo "$SUITE_WORK/xnnpack-on-cpu" xnnpack
status=0
run_demo "$SUITE_WORK/unknown" tensorrt >/dev/null 2>&1 || status=$?
[[ $status -eq 2 && ! -e "$SUITE_WORK/unknown" ]] || { echo "An unknown device gave status $status" >&2; exit 1; }
detector_fixture_faults bash "$DETECTOR_CHECK" "$SUITE_WORK/demo" "$SUITE_WORK/model.onnx" cuda -- \
  BAD_GPU_PROFILE BAD_GPU_OUTPUT BAD_GPU_REPEAT BAD_GPU_SECOND_PROFILE BAD_CPU_REPEAT MISSING_CPU_REPEAT BAD_CPU_SECOND_PROFILE
run_mutant() { bash "$1" "$SUITE_WORK/demo" "$SUITE_WORK/model.onnx" cuda "$SUITE_WORK/mutant"; }
EDGE_PARITY=1 detector_fixture_pairwise_mutant 's/ --pairwise$//' run_mutant
detector_fixture_changed_model run_demo "$SUITE_WORK/invalid-model"
echo 'Detector parity orchestration checks passed'
