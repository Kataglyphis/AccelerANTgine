#!/usr/bin/env bash
# Investigate a documented process-local MIGraphX setting; this is not a release gate.
set -euo pipefail
# shellcheck source=lib/detector-evidence.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/detector-evidence.sh"
detector_evidence_args 5 'diagnose-migraphx-detector.sh DEMO MODEL FIXTURE exhaustive|skip-rocblas|skip-no-mlir NEW_EVIDENCE_DIR' "$@"
fixture=$(realpath -e "$3") mode=$4
case "$mode" in
  exhaustive) setting=(ORT_MIGRAPHX_EXHAUSTIVE_TUNE=1) ;;
  skip-rocblas) setting=(MIGRAPHX_SKIP_BENCHMARKING=1 MIGRAPHX_SET_GEMM_PROVIDER=rocblas) ;;
  skip-no-mlir) setting=(MIGRAPHX_SKIP_BENCHMARKING=1 MIGRAPHX_DISABLE_MLIR=1) ;;
  *) echo 'Unsupported diagnostic mode' >&2; exit 2 ;;
esac
detector_evidence_prepare 'Demo, model, fixture or shared helpers are missing' "$fixture" "$5"
evidence=$DETECTOR_EVIDENCE_DIR
for selected in cpu migraphx; do
  extra=()
  [[ "$selected" != migraphx ]] || extra=("${setting[@]}")
  detector_evidence_leg "$selected" "$selected" "$selected-1" "$selected-2" \
    timeout --signal=TERM --kill-after=15s 240s -- "${extra[@]}"
done
cmp "$evidence/cpu-1.json" "$evidence/cpu-2.json"
status=0
for pair in 'cpu-1 migraphx-1' 'cpu-2 migraphx-2'; do
  read -r left right <<<"$pair"
  echo "Comparing $left with $right"
  if ! detector_evidence_compare "$left" "$right"; then status=1; fi
done
echo 'Comparing migraphx-1 with migraphx-2'
if ! detector_evidence_compare migraphx-1 migraphx-2 --pairwise; then status=1; fi
[[ $status -eq 0 ]] || exit "$status"
echo "Diagnostic $mode passed; this does not establish release verification"
