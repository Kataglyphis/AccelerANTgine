#!/usr/bin/env bash
# Run the locked model with each packaged runtime loader on a clean host.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo 'usage: check-clean-host-inference.sh --demo EXECUTABLE MODEL | --appimage APPIMAGE MODEL' >&2
  exit 2
fi
kind=$1 target=$2 model=$3
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/accelerantgine-cpu-check.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
case "$kind" in
  --demo) demo=$target ;;
  --appimage)
    target="$(realpath "$target")"
    (cd "$work" && "$target" --appimage-extract >/dev/null)
    demo="$work/squashfs-root/usr/bin/AccelerANTgine_demo"
    ;;
  *) echo 'Expected --demo or --appimage' >&2; exit 2 ;;
esac
[[ -x "$demo" && -r "$model" ]] || { echo 'Packaged demo or locked model is missing' >&2; exit 1; }
private="$(dirname "$(realpath "$demo")")/../lib/accelerantgine"
libav="$private/gstreamer-1.0/libgstlibav.so"
[[ -f "$libav" ]] || { echo 'Packaged GStreamer libav plugin is missing' >&2; exit 1; }
if ! env LD_LIBRARY_PATH="$private" ldd "$libav" >"$work/libav.log" 2>&1 || grep -q 'not found' "$work/libav.log"; then
  cat "$work/libav.log" >&2
  echo 'GStreamer libav dependencies did not resolve' >&2
  exit 1
fi
for mode in host bundled; do
  args=(env -u LD_LIBRARY_PATH -u KATAGLYPHIS_BUNDLED_GLIBC)
  if [[ "$mode" == bundled ]]; then args+=(KATAGLYPHIS_BUNDLED_GLIBC=1); fi
  if ! "${args[@]}" "$demo" --onnx-only --model "$model" --device cpu >"$work/$mode.log" 2>&1; then
    cat "$work/$mode.log" >&2
    exit 1
  fi
  if ! grep -Fq 'Output 0 shape: [1, 300, 6] (1800 elements)' "$work/$mode.log"; then
    cat "$work/$mode.log" >&2
    echo "Unexpected output from the $mode runtime" >&2
    exit 1
  fi
  echo "$mode runtime: locked-model CPU inference passed"
done
