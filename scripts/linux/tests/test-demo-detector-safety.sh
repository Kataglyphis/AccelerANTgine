#!/usr/bin/env bash
# Check that the detector diagnostic preserves existing image and profile paths.
set -euo pipefail
if [[ $# -ne 3 ]]; then echo 'usage: test-demo-detector-safety.sh DEMO MODEL FIXTURE.jpg' >&2; exit 2; fi
demo=$(realpath -e "$1") model=$(realpath -e "$2") fixture=$(realpath -e "$3")
work=$(mktemp -d "${TMPDIR:-/tmp}/accelerant-demo-safety.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
before=$(sha256sum "$fixture")
if "$demo" --model "$model" --device cpu --detector-image "$fixture" --detector-output "$fixture" \
  --profile "$work/unused-profile"; then
  echo 'Existing detector output was accepted' >&2; exit 1
fi
[[ $(sha256sum "$fixture") == "$before" && ! -e "$work/unused-profile" ]]
if "$demo" --model "$model" --device cpu --detector-image "$fixture" --detector-output "$work/first.json" \
  --detector-repeat-output "$fixture" --profile "$work/unused-repeat-profile"; then
  echo 'Existing repeated detector output was accepted' >&2; exit 1
fi
[[ $(sha256sum "$fixture") == "$before" && ! -e "$work/unused-repeat-profile" ]]
mkdir "$work/existing-profile"
printf 'preserve\n' >"$work/existing-profile/sentinel"
if "$demo" --model "$model" --device cpu --detector-image "$fixture" --detector-output "$work/result.json" \
  --profile "$work/existing-profile"; then
  echo 'Existing detector profile directory was accepted' >&2; exit 1
fi
[[ $(cat "$work/existing-profile/sentinel") == preserve ]]
printf 'not a JPEG\n' >"$work/bad.jpg"
if "$demo" --model "$model" --device cpu --detector-image "$work/bad.jpg" --detector-output "$work/bad-result.json" \
  --profile "$work/bad-profile"; then
  echo 'Invalid detector image was accepted' >&2; exit 1
fi
[[ ! -s "$work/bad-result.json" ]]
echo 'Existing detector output and profile directory were preserved'
