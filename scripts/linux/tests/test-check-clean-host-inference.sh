#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
check="$repo/scripts/linux/check-clean-host-inference.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
export PROOF_DIR="$work"
touch "$work/model.onnx"
mkdir -p "$work/usr/bin" "$work/usr/lib/accelerantgine/gstreamer-1.0" "$work/bin"
touch "$work/usr/lib/accelerantgine/gstreamer-1.0/libgstlibav.so"
cat >"$work/usr/bin/AccelerANTgine_demo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 5 && ( $1 == --onnx-only || $1 == --video-check ) && $2 == --model && $4 == --device && $5 == cpu ]]
[[ -z ${LD_LIBRARY_PATH+x} ]]
printf '%s %s\n' "${KATAGLYPHIS_BUNDLED_GLIBC:-host}" "$1" >>"$PROOF_DIR/modes"
if [[ $1 == --onnx-only ]]; then
  if [[ ${BAD_OUTPUT:-0} == 1 ]]; then echo 'bad shape'; else echo 'Output 0 shape: [1, 300, 6] (1800 elements)'; fi
else
  [[ ${GST_PLUGIN_PATH_1_0:-} == */accelerantgine-cpu-check.*/outside-plugins ]]
  if [[ ${BAD_VIDEO:-0} == 1 ]]; then echo 'bad video'; else echo 'GStreamer video frame inference passed'; fi
fi
STUB
cat >"$work/bin/ldd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && -f $1 && -d $LD_LIBRARY_PATH ]]
if [[ ${BAD_LIBRARY:-0} == 1 ]]; then echo 'libXrender.so.1 => not found'; else echo 'libraries resolved'; fi
STUB
cat >"$work/fake.AppImage" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && $1 == --appimage-extract ]]
mkdir -p squashfs-root/usr
cp -R "$PROOF_DIR/usr/bin" "$PROOF_DIR/usr/lib" squashfs-root/usr/
STUB
chmod +x "$work/usr/bin/AccelerANTgine_demo" "$work/bin/ldd" "$work/fake.AppImage"
export PATH="$work/bin:$PATH"
export LD_LIBRARY_PATH=/untrusted KATAGLYPHIS_BUNDLED_GLIBC=unexpected
bash "$check" --demo "$work/usr/bin/AccelerANTgine_demo" "$work/model.onnx"
bash "$check" --appimage "$work/fake.AppImage" "$work/model.onnx"
[[ "$(cat "$work/modes")" == $'host --onnx-only\nhost --video-check\n1 --onnx-only\n1 --video-check\nhost --onnx-only\nhost --video-check\n1 --onnx-only\n1 --video-check' ]]
if BAD_OUTPUT=1 bash "$check" --demo "$work/usr/bin/AccelerANTgine_demo" "$work/model.onnx" >/dev/null 2>&1; then
  echo 'Wrong model output unexpectedly passed' >&2
  exit 1
fi
if BAD_VIDEO=1 bash "$check" --demo "$work/usr/bin/AccelerANTgine_demo" "$work/model.onnx" >/dev/null 2>&1; then
  echo 'A failed video inference unexpectedly passed' >&2
  exit 1
fi
if BAD_LIBRARY=1 bash "$check" --demo "$work/usr/bin/AccelerANTgine_demo" "$work/model.onnx" >/dev/null 2>&1; then
  echo 'An unresolved libav dependency unexpectedly passed' >&2
  exit 1
fi
if bash "$check" --demo "$work/usr/bin/AccelerANTgine_demo" "$work/missing.onnx" >/dev/null 2>&1; then
  echo 'A missing model unexpectedly passed' >&2
  exit 1
fi
echo 'Clean-host inference checks passed.'
