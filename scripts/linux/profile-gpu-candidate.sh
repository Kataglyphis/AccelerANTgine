#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then echo 'usage: profile-gpu-candidate.sh ARTIFACT_DIR MODEL DEVICE' >&2; exit 2; fi
artifact_dir=$1 model=$2 device=$3
case "$device" in cpu|cuda|migraphx) ;; *) echo 'Unsupported profile device' >&2; exit 2 ;; esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shopt -s nullglob
archives=("$artifact_dir"/*.tar.gz)
[[ ${#archives[@]} -eq 1 ]] || { echo 'Expected one candidate tarball' >&2; exit 1; }
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/accelerantgine-profile.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
tar -xzf "${archives[0]}" -C "$stage"
mapfile -d '' -t demos < <(find "$stage" -type f -path '*/usr/bin/AccelerANTgine_demo' -print0)
[[ ${#demos[@]} -eq 1 && -x ${demos[0]} ]] || { echo 'Expected one executable packaged demo wrapper' >&2; exit 1; }
"${demos[0]}" --onnx-only --model "$model" --device "$device" --profile "$stage/ort-profile"
profiles=("$stage"/ort-profile*.json)
[[ ${#profiles[@]} -eq 1 ]] || { echo 'Expected one ORT profile' >&2; exit 1; }
python3 -I "$repo/third_party/ANTfrastructure/shared/python/verify_ort_profile.py" "${profiles[0]}" --device "$device"
"${demos[0]}" --video-check --model "$model" --device "$device" --profile "$stage/video-profile"
profiles=("$stage"/video-profile*.json)
[[ ${#profiles[@]} -eq 1 ]] || { echo 'Expected one video inference ORT profile' >&2; exit 1; }
python3 -I "$repo/third_party/ANTfrastructure/shared/python/verify_ort_profile.py" "${profiles[0]}" --device "$device"
