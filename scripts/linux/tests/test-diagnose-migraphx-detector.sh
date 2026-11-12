#!/usr/bin/env bash
# Exercise diagnostic settings, output comparisons and profile failures without a GPU.
set -euo pipefail
# shellcheck source=detector-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/detector-fixture.sh"
detector_fixture_tree diagnose-migraphx-detector.sh "$@"
detector_fixture_shared_helpers
FIXTURE_GPU_PROVIDER=$(detector_fixture_hub_provider migraphx)
export FIXTURE_GPU_PROVIDER
detector_fixture_demo <<'POLICY'
[[ -z ${MIGRAPHX_UNKNOWN+x} ]]
provider=CPUExecutionProvider
if [[ "$device" == cpu ]]; then
  [[ -z ${MIGRAPHX_SKIP_BENCHMARKING+x} && -z ${ORT_MIGRAPHX_EXHAUSTIVE_TUNE+x} ]]
else
  provider=$FIXTURE_GPU_PROVIDER
  case "$EXPECT_MODE" in
    exhaustive) [[ ${ORT_MIGRAPHX_EXHAUSTIVE_TUNE:-} == 1 && -z ${MIGRAPHX_SKIP_BENCHMARKING+x} ]] ;;
    skip-rocblas) [[ ${MIGRAPHX_SKIP_BENCHMARKING:-} == 1 && ${MIGRAPHX_SET_GEMM_PROVIDER:-} == rocblas ]] ;;
    skip-no-mlir) [[ ${MIGRAPHX_SKIP_BENCHMARKING:-} == 1 && ${MIGRAPHX_DISABLE_MLIR:-} == 1 ]] ;;
    *) exit 1 ;;
  esac
fi
[[ ${BAD_REPEAT:-0} != 1 || "$device" == cpu ]] || repeat_fault=bad
POLICY
# Usage: run_mode MODE EVIDENCE; EXPECT_MODE is the setting the synthetic demo requires.
run_mode() { EXPECT_MODE="$1" bash "$DETECTOR_CHECK" "$SUITE_WORK/demo" "$SUITE_WORK/model.onnx" "$DETECTOR_FIXTURE" "$1" "$2"; }
run_rocblas() { run_mode skip-rocblas "$1"; }
run_exhaustive() { run_mode exhaustive "$1"; }
detector_fixture_legacy_tool compare_detector_parity.py --pairwise 'A comparator without pairwise support was accepted' \
  'Old comparator was checked too late' run_rocblas "$SUITE_WORK/legacy"
detector_fixture_missing_hub_files run_exhaustive
for mode in exhaustive skip-rocblas skip-no-mlir; do
  MIGRAPHX_SKIP_BENCHMARKING=poison ORT_MIGRAPHX_EXHAUSTIVE_TUNE=poison MIGRAPHX_UNKNOWN=poison run_mode "$mode" "$SUITE_WORK/$mode"
done
EDGE_PARITY=1 run_rocblas "$SUITE_WORK/edge"
run_mutant() { EXPECT_MODE=skip-rocblas bash "$1" "$SUITE_WORK/demo" "$SUITE_WORK/model.onnx" "$DETECTOR_FIXTURE" skip-rocblas "$SUITE_WORK/mutant"; }
EDGE_PARITY=1 detector_fixture_pairwise_mutant 's/ --pairwise; then/; then/' run_mutant
EXPECT_MODE=skip-rocblas detector_fixture_faults bash "$DETECTOR_CHECK" "$SUITE_WORK/demo" "$SUITE_WORK/model.onnx" "$DETECTOR_FIXTURE" skip-rocblas -- \
  BAD_REPEAT BAD_GPU_SECOND_PROFILE
detector_fixture_changed_model run_exhaustive "$SUITE_WORK/invalid"
echo 'MIGraphX diagnostic settings and failure checks passed'
