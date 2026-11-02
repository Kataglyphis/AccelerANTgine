#!/usr/bin/env bash
# Shared inputs and legs of the detector checks; callers keep their own usage, comparisons and verdicts.

DETECTOR_EVIDENCE_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DETECTOR_EVIDENCE_SHARED="$DETECTOR_EVIDENCE_REPO/third_party/ANTfrastructure/shared/python"
DETECTOR_EVIDENCE_GST_UNSET=(-u GST_PLUGIN_PATH -u GST_PLUGIN_PATH_1_0 -u GST_PLUGIN_SYSTEM_PATH -u GST_PLUGIN_SYSTEM_PATH_1_0
  -u GST_PLUGIN_SCANNER -u GST_PLUGIN_SCANNER_1_0 -u GST_REGISTRY -u GST_REGISTRY_1_0 -u GST_REGISTRY_FORK)
DETECTOR_EVIDENCE_CLEAN=(env -u LD_PRELOAD -u LD_AUDIT -u ORT_DYLIB_PATH -u ORT_LIB_LOCATION -u KATAGLYPHIS_ONNX_MODEL
  -u KATAGLYPHIS_ONNX_BACKEND -u KATAGLYPHIS_ORT_DEVICE "${DETECTOR_EVIDENCE_GST_UNSET[@]}")

# Usage: detector_evidence_args WANT USAGE DEMO MODEL [MORE...]; a wrong count exits 2 before any path is resolved.
detector_evidence_args() {
  local want=$1 usage=$2
  shift 2
  if [[ $# -ne $want ]]; then echo "usage: $usage" >&2; exit 2; fi
  DETECTOR_DEMO=$(realpath -e "$1")
  DETECTOR_MODEL=$(realpath -e "$2")
}

# Exits rather than returns so a missing hub API stops the caller before it creates evidence.
detector_evidence_load_gpu_env() {
  local gpu_env="$DETECTOR_EVIDENCE_REPO/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
  [[ -f "$gpu_env" ]] || { echo 'Pinned ANTfrastructure lacks GPU profile environment isolation' >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$gpu_env"
  declare -F gpu_without_migraphx_overrides >/dev/null || { echo 'Pinned GPU environment helper lacks its API' >&2; exit 1; }
}

# Usage: detector_evidence_prepare MISSING_MESSAGE FIXTURE NEW_EVIDENCE_DIR; proves every input before creating the directory.
detector_evidence_prepare() {
  local repo=$DETECTOR_EVIDENCE_REPO missing_message=$1 parity_help profile_help
  _detector_fixture=$2
  [[ -x "$DETECTOR_DEMO" && -f "$DETECTOR_MODEL" && -f "$_detector_fixture" && -f "$DETECTOR_EVIDENCE_SHARED/verify_ort_profile.py" && -f "$DETECTOR_EVIDENCE_SHARED/compare_detector_parity.py" ]] || {
    echo "$missing_message" >&2; exit 1;
  }
  detector_evidence_load_gpu_env
  parity_help=$(python3 -I "$DETECTOR_EVIDENCE_SHARED/compare_detector_parity.py" --help)
  profile_help=$(python3 -I "$DETECTOR_EVIDENCE_SHARED/verify_ort_profile.py" --help)
  [[ "$parity_help" == *--pairwise* && "$profile_help" == *--min-runs* ]] || {
    echo 'Pinned shared helpers lack pairwise or per-run verification' >&2; exit 1;
  }
  local -a locked_hashes
  mapfile -t locked_hashes < <(awk '$2 == "deim_dfine_n_coco.onnx" {print $1}' "$repo/models/models.lock")
  [[ ${#locked_hashes[@]} -eq 1 && ${locked_hashes[0]} =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid model lock' >&2; exit 1; }
  printf '%s  %s\n' "${locked_hashes[0]}" "$DETECTOR_MODEL" | sha256sum -c -
  printf '%s  %s\n' '6d375ac20fadfd400b3033084f8b0581dcc145f7c14e3b24b97975e379c52999' "$_detector_fixture" | sha256sum -c -
  mkdir -- "$3"
  DETECTOR_EVIDENCE_DIR=$(realpath -e "$3")
  _detector_fixture=$(realpath -e "$_detector_fixture")
}

# Usage: detector_evidence_verify_profile LABEL DEVICE MIN_RUNS PROFILES...; MIN_RUNS 0 leaves the verifier's own default.
detector_evidence_verify_profile() {
  local label=$1 device=$2 min_runs=$3
  shift 3
  [[ $# -eq 1 ]] || { echo "Expected one $label profile" >&2; exit 1; }
  local -a runs=()
  [[ "$min_runs" == 0 ]] || runs=(--min-runs "$min_runs")
  python3 -I "$DETECTOR_EVIDENCE_SHARED/verify_ort_profile.py" "$1" --device "$device" "${runs[@]}"
}

# Usage: detector_evidence_inside ROOT PATH LABEL; prints the resolved PATH, or refuses one that escapes ROOT.
detector_evidence_inside() {
  local resolved
  resolved="$(realpath -e "$2")"
  case "$resolved" in "$1"/*) ;; *) echo "$3 escapes its package" >&2; exit 1 ;; esac
  printf '%s\n' "$resolved"
}

# Usage: detector_evidence_leg LABEL DEVICE OUTPUT REPEAT [WRAPPER...] -- [ENV_ARGUMENT...]; the demo runs twice in one session and both profiled runs are proved.
detector_evidence_leg() {
  local label=$1 device=$2 output=$3 repeat=$4 evidence=$DETECTOR_EVIDENCE_DIR
  local -a wrapper=()
  shift 4
  while [[ $1 != -- ]]; do wrapper+=("$1"); shift; done
  shift
  gpu_without_migraphx_overrides "${wrapper[@]}" "${DETECTOR_EVIDENCE_CLEAN[@]}" "$@" GST_REGISTRY_1_0="$evidence/$label-gst-registry.bin" "$DETECTOR_DEMO" --model "$DETECTOR_MODEL" --device "$device" \
    --detector-image "$_detector_fixture" --detector-output "$evidence/$output.json" \
    --detector-repeat-output "$evidence/$repeat.json" --profile "$evidence/$label-profile"
  shopt -s nullglob
  detector_evidence_verify_profile "$label detector" "$device" 2 "$evidence/$label-profile/"*.json
}

# Usage: detector_evidence_compare LEFT RIGHT [--pairwise]; both are evidence basenames.
detector_evidence_compare() {
  python3 -I "$DETECTOR_EVIDENCE_SHARED/compare_detector_parity.py" "$DETECTOR_EVIDENCE_DIR/$1.json" "$DETECTOR_EVIDENCE_DIR/$2.json" "${@:3}"
}
