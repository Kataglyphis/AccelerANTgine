#!/usr/bin/env bash
# Verify CPU and accelerated (GPU, XNNPACK or DNNL) detector results and profiles on the pinned ModelANT image.
set -euo pipefail
# shellcheck source=lib/detector-evidence.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/detector-evidence.sh"
detector_evidence_args 4 'check-gpu-detector-parity.sh DEMO MODEL cuda|migraphx|xnnpack|dnnl NEW_EVIDENCE_DIR' "$@"
device=$3
case "$device" in cuda|migraphx|xnnpack|dnnl) ;; *) echo 'Unsupported accelerated device' >&2; exit 2 ;; esac
fixture="$DETECTOR_EVIDENCE_REPO/third_party/ModelANT/contracts/fixtures/two_cats.jpg"
detector_evidence_prepare 'Demo, locked model, fixture or shared parity helpers are missing' "$fixture" "$4"
for run in cpu gpu; do
  selected=$device
  [[ "$run" != cpu ]] || selected=cpu
  clean=()
  # A GPU's CPU leg proves the package alone; a CPU provider compares with CPU in the same environment.
  if [[ "$selected" == cpu && "$device" != xnnpack && "$device" != dnnl ]]; then clean+=(-u LD_LIBRARY_PATH); fi
  detector_evidence_leg "$run" "$selected" "${run}1" "${run}2" -- "${clean[@]}"
done
detector_evidence_compare cpu1 cpu2
detector_evidence_compare cpu1 gpu1
detector_evidence_compare cpu1 gpu2
detector_evidence_compare gpu1 gpu2 --pairwise
echo "Detector parity evidence: $DETECTOR_EVIDENCE_DIR"
