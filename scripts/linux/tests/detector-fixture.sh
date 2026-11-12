#!/usr/bin/env bash
# Synthetic detector tree and demo for the parity and MIGraphX suites; no GPU, ONNX Runtime or real inference runs.

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"

# Usage: detector_fixture_tree SCRIPT [HUB]; sets the paths the suites and the helpers below read.
detector_fixture_tree() {
  DETECTOR_WORK=$SUITE_WORK
  DETECTOR_HUB=${2:-"$SUITE_ROOT/third_party/ANTfrastructure"}
  DETECTOR_REPO="$DETECTOR_WORK/repo"
  DETECTOR_CHECK="$DETECTOR_REPO/scripts/linux/$1"
  DETECTOR_SHARED="$DETECTOR_REPO/third_party/ANTfrastructure/shared/python"
  DETECTOR_LIB="$DETECTOR_REPO/third_party/ANTfrastructure/linux/scripts/lib"
  export DETECTOR_FIXTURE="$SUITE_ROOT/third_party/ModelANT/contracts/fixtures/two_cats.jpg"
  mkdir -p "$DETECTOR_REPO/scripts/linux/lib" "$DETECTOR_REPO/models" "$DETECTOR_SHARED" "$DETECTOR_LIB"
  cp "$DETECTOR_HUB/linux/scripts/lib/gpu-profile-env.sh" "$DETECTOR_HUB/linux/scripts/lib/log-bootstrap.sh" "$DETECTOR_LIB/"
  cp "$SUITE_ROOT/scripts/linux/$1" "$DETECTOR_REPO/scripts/linux/"
  cp "$SUITE_ROOT/scripts/linux/lib/detector-evidence.sh" "$DETECTOR_REPO/scripts/linux/lib/"
  printf 'test model\n' >"$DETECTOR_WORK/model.onnx"
  printf '%s  deim_dfine_n_coco.onnx\n' "$(sha256sum "$DETECTOR_WORK/model.onnx" | cut -d ' ' -f 1)" >"$DETECTOR_REPO/models/models.lock"
}

detector_fixture_shared_helpers() {
  cp "$DETECTOR_HUB/shared/python/verify_ort_profile.py" "$DETECTOR_HUB/shared/python/compare_detector_parity.py" "$DETECTOR_SHARED/"
}

# Usage: detector_fixture_hub_provider DEVICE; the pinned hub's checker owns the name it accepts, the suites prove the wiring.
detector_fixture_hub_provider() {
  python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["PROVIDERS"][sys.argv[2]], end="")' \
    "$DETECTOR_HUB/shared/python/verify_ort_profile.py" "$1"
}

# Usage: detector_fixture_demo; the policy on stdin runs after argument parsing and may set provider, provider2, score and repeat_fault; BAD_GPU_SECOND_PROFILE=1 is the shared fault.
detector_fixture_demo() {
  {
    cat <<'DEMO'
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
score=0.90 second_score=0.8 repeat_fault=
DEMO
    cat
    cat <<'DEMO'
provider2=${provider2:-$provider}
[[ ${BAD_GPU_SECOND_PROFILE:-0} != 1 || "$device" == cpu ]] || provider2=CPUExecutionProvider
if [[ ${EDGE_PARITY:-0} == 1 ]]; then
  score=0.80
  [[ "$device" == cpu ]] || score=0.76
  second_score=0.78
fi
printf '{"schema_version":1,"width":480,"height":659,"detections":[{"class":15,"score":%s,"box":[0,250,450,640]},{"class":15,"score":%s,"box":[0,0,250,200]}]}\n' "$score" "$second_score" >"$output"
case "$repeat_fault" in
  bad) printf '{"schema_version":1,"width":480,"height":659,"detections":[{"class":15,"score":0.3,"box":[0,250,450,640]}]}\n' >"$repeat" ;;
  missing) ;;
  *) cp "$output" "$repeat" ;;
esac
mkdir "$profile"
printf '[{"cat":"Session","name":"model_run","ph":"X","pid":42,"ts":0,"dur":10},{"cat":"Node","ph":"X","pid":42,"ts":1,"dur":1,"args":{"provider":"%s","op_name":"Conv"}},{"cat":"Session","name":"model_run","ph":"X","pid":42,"ts":20,"dur":10},{"cat":"Node","ph":"X","pid":42,"ts":21,"dur":1,"args":{"provider":"%s","op_name":"Conv"}}]\n' "$provider" "$provider2" >"$profile/ort.json"
DEMO
  } >"$DETECTOR_WORK/demo"
  chmod +x "$DETECTOR_WORK/demo"
}

# Usage: detector_fixture_refused_early MESSAGE LATE_MESSAGE RUNNER EVIDENCE; RUNNER gets the evidence path and must not create it.
detector_fixture_refused_early() {
  suite_refuses "$1" "$3" "$4"
  [[ ! -e "$4" ]] || { echo "$2" >&2; exit 1; }
}

# Usage: detector_fixture_legacy_tool TOOL FLAG MESSAGE LATE_MESSAGE RUNNER EVIDENCE; an older hub tool lacks FLAG.
detector_fixture_legacy_tool() {
  sed "s/$2/--legacy-${2#--}/g" "$DETECTOR_HUB/shared/python/$1" >"$DETECTOR_SHARED/$1"
  detector_fixture_refused_early "$3" "$4" "$5" "$6"
  cp "$DETECTOR_HUB/shared/python/$1" "$DETECTOR_SHARED/$1"
}

# Usage: detector_fixture_missing_hub_files RUNNER; each hub file is removed for one refused run and then restored.
detector_fixture_missing_hub_files() {
  mv "$DETECTOR_LIB/gpu-profile-env.sh" "$DETECTOR_WORK/gpu-profile-env.sh"
  detector_fixture_refused_early 'Missing GPU environment helper was accepted' 'Missing helper was checked too late' "$1" "$DETECTOR_WORK/missing-env"
  mv "$DETECTOR_WORK/gpu-profile-env.sh" "$DETECTOR_LIB/gpu-profile-env.sh"
  mv "$DETECTOR_LIB/log-bootstrap.sh" "$DETECTOR_WORK/log-bootstrap.sh"
  detector_fixture_refused_early 'Missing GPU environment logging bootstrap was accepted' 'Missing bootstrap was checked too late' "$1" "$DETECTOR_WORK/missing-bootstrap"
  mv "$DETECTOR_WORK/log-bootstrap.sh" "$DETECTOR_LIB/log-bootstrap.sh"
}

# Usage: detector_fixture_pairwise_mutant SED_EXPRESSION RUNNER...; the mutant's path is passed as RUNNER's first argument.
detector_fixture_pairwise_mutant() {
  local mutant="$DETECTOR_REPO/scripts/linux/without-pairwise.sh" expression=$1
  shift
  sed "$expression" "$DETECTOR_CHECK" >"$mutant"
  suite_refuses_logged 'GPU repeat wrongly accepted with the CPU-only oracle' 'CPU baseline did not detect both expected cats' \
    "$DETECTOR_WORK/mutant.log" "$@" "$mutant"
}

# Usage: detector_fixture_faults RUNNER... -- FAULT...; RUNNER takes the evidence path and each FAULT=1 must be refused.
detector_fixture_faults() {
  local -a runner=()
  while [[ $1 != -- ]]; do runner+=("$1"); shift; done
  shift
  local fault
  for fault in "$@"; do
    suite_refuses "$fault was accepted" env "$fault=1" "${runner[@]}" "$SUITE_WORK/$fault"
  done
}

# Usage: detector_fixture_changed_model RUNNER EVIDENCE; the lock must refuse a model whose bytes moved.
detector_fixture_changed_model() {
  printf 'altered\n' >>"$DETECTOR_WORK/model.onnx"
  suite_refuses 'Changed model was accepted' "$1" "$2"
}
