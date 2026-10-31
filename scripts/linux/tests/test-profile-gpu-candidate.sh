#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bundle/usr/bin" "$work/bundle/usr/lib/accelerantgine" "$work/artifacts" "$work/bin"
cat > "$work/bundle/usr/bin/AccelerANTgine_demo" <<'STUB'
#!/usr/bin/env bash
[[ "$2" == --model && "$3" == "$TEST_MODEL" ]]
if [[ "$1" == --onnx-only ]]; then
  [[ $# -eq 5 && "$4" == --profile ]]
  profile="$5"
  mode=default
else
  [[ "$1" == --video-check && $# -eq 7 && "$4" == --device && "$6" == --profile ]]
  profile="$7"
  mode="$5"
fi
[[ "$LD_LIBRARY_PATH" == "$TEST_SDK_PATH" && -z "${GST_PLUGIN_PATH+x}" && -z "${GST_PLUGIN_PATH_1_0+x}" ]]
[[ -z "${LD_PRELOAD+x}" && -z "${LD_AUDIT+x}" ]]
[[ -z "${GST_PLUGIN_SYSTEM_PATH_1_0+x}" && -z "${GST_REGISTRY+x}" && -z "${GST_PLUGIN_SCANNER+x}" ]]
case "$0" in
  */tar/*) kind=tar ;;
  */appimage/squashfs-root/*) kind=appimage ;;
  */deb/*) kind=deb ;;
  *) echo 'Demo not run from the candidate payload' >&2; exit 1 ;;
esac
[[ "$GST_REGISTRY_1_0" == "$RUNNER_TEMP"/accelerantgine-profile.*/"$kind"-gst-registry.bin ]]
[[ "$profile" == "$RUNNER_TEMP"/accelerantgine-profile.*/"$kind"-* ]]
printf '%s %s %s\n' "$kind" "$1" "$mode" >> "${TEST_DEMO_LOG:?}"
printf '[]\n' > "$profile.json"
STUB
cat > "$work/bundle/usr/lib/accelerantgine/AccelerANTgine_demo" <<'STUB'
#!/usr/bin/env bash
echo 'The library binary bypasses the packaged wrapper' >&2
exit 1
STUB
cat > "$work/bin/python3" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -I && "$2" == */verify_ort_profile.py && -f "$3" && "$4" == --device && "$5" == cuda ]]
if [[ ${FAIL_DEFAULT_PROFILE:-0} == 1 && "$3" == *-ort-profile* ]]; then exit 1; fi
if [[ ${FAIL_VIDEO_PROFILE:-0} == 1 && "$3" == *-video-profile* ]]; then exit 1; fi
if [[ ${FAIL_APPIMAGE_PROFILE:-0} == 1 && "$3" == */appimage-ort-profile* ]]; then exit 1; fi
if [[ ${FAIL_DEB_PROFILE:-0} == 1 && "$3" == */deb-ort-profile* ]]; then exit 1; fi
if [[ ${FAIL_DEB_VIDEO_PROFILE:-0} == 1 && "$3" == */deb-video-profile* ]]; then exit 1; fi
STUB
cat > "$work/artifacts/candidate.AppImage" <<'STUB'
#!/usr/bin/env bash
[[ $# -eq 1 && "$1" == --appimage-extract ]]
[[ ${FAIL_APPIMAGE_EXTRACT:-0} != 1 ]] || exit 1
mkdir squashfs-root
cp -a "${TEST_APPIMAGE_TREE:?}/." squashfs-root/
STUB
chmod +x "$work/bundle/usr/bin/AccelerANTgine_demo" "$work/bundle/usr/lib/accelerantgine/AccelerANTgine_demo" "$work/bin/python3"
tar -czf "$work/artifacts/candidate.tar.gz" -C "$work" bundle
mkdir -p "$work/deb-package/DEBIAN"
cp -a "$work/bundle/usr" "$work/deb-package/usr"
printf 'Package: accelerantgine-fixture\nVersion: 1\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: profile fixture\n' > "$work/deb-package/DEBIAN/control"
dpkg-deb --build --root-owner-group "$work/deb-package" "$work/artifacts/candidate.deb" >/dev/null
cp -a "$work/bundle" "$work/appimage-tree"
export PATH="$work/bin:$PATH" TEST_DEMO_LOG="$work/demo.log" RUNNER_TEMP="$work"
export TEST_APPIMAGE_TREE="$work/appimage-tree"
export TEST_MODEL="$work/model.onnx"
touch "$TEST_MODEL"
export LD_LIBRARY_PATH="$work/gpu-sdk" TEST_SDK_PATH="$work/gpu-sdk"
export LD_PRELOAD='' LD_AUDIT=''
export GST_PLUGIN_PATH="$work/host-plugin" GST_PLUGIN_PATH_1_0="$work/host-plugin"
export GST_PLUGIN_SYSTEM_PATH_1_0="$work/host-system" GST_REGISTRY="$work/host-registry" GST_PLUGIN_SCANNER="$work/host-scanner"
bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda
[[ "$(cat "$TEST_DEMO_LOG")" == $'tar --onnx-only default\ntar --video-check cuda\nappimage --onnx-only default\nappimage --video-check cuda\ndeb --onnx-only default\ndeb --video-check cuda' ]] || {
  echo 'Expected direct and video profiling from every package' >&2; exit 1;
}
if FAIL_DEFAULT_PROFILE=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected default-device profile was accepted' >&2; exit 1
fi
if FAIL_VIDEO_PROFILE=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected video profile was accepted' >&2; exit 1
fi
if FAIL_APPIMAGE_PROFILE=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected AppImage profile was accepted' >&2; exit 1
fi
if FAIL_DEB_PROFILE=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected DEB profile was accepted' >&2; exit 1
fi
if FAIL_DEB_VIDEO_PROFILE=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected DEB video profile was accepted' >&2; exit 1
fi
if FAIL_APPIMAGE_EXTRACT=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A failed AppImage extraction was accepted' >&2; exit 1
fi
mv "$work/artifacts/candidate.AppImage" "$work/candidate.AppImage"
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A missing AppImage was accepted' >&2; exit 1
fi
mv "$work/candidate.AppImage" "$work/artifacts/candidate.AppImage"
cp "$work/artifacts/candidate.AppImage" "$work/artifacts/duplicate.AppImage"
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'Duplicate AppImages were accepted' >&2; exit 1
fi
rm "$work/artifacts/duplicate.AppImage"
mv "$work/artifacts/candidate.deb" "$work/candidate.deb"
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A missing DEB was accepted' >&2; exit 1
fi
mv "$work/candidate.deb" "$work/artifacts/candidate.deb"
cp "$work/artifacts/candidate.deb" "$work/artifacts/duplicate.deb"
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'Duplicate DEBs were accepted' >&2; exit 1
fi
rm "$work/artifacts/duplicate.deb"
mv "$work/artifacts/candidate.deb" "$work/candidate.deb"
printf 'not a DEB' > "$work/artifacts/candidate.deb"
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A corrupt DEB was accepted' >&2; exit 1
fi
rm "$work/artifacts/candidate.deb"
rm "$work/deb-package/usr/bin/AccelerANTgine_demo"
ln -s ../../lib/accelerantgine/AccelerANTgine_demo "$work/deb-package/usr/bin/AccelerANTgine_demo"
dpkg-deb --build --root-owner-group "$work/deb-package" "$work/artifacts/candidate.deb" >/dev/null
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A DEB with a linked demo wrapper was accepted' >&2; exit 1
fi
mv "$work/candidate.deb" "$work/artifacts/candidate.deb"
rm "$work/appimage-tree/usr/bin/AccelerANTgine_demo"
ln -s ../../lib/accelerantgine/AccelerANTgine_demo "$work/appimage-tree/usr/bin/AccelerANTgine_demo"
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'An AppImage with a linked demo wrapper was accepted' >&2; exit 1
fi
rm "$work/bundle/usr/bin/AccelerANTgine_demo"
tar -czf "$work/artifacts/candidate.tar.gz" -C "$work" bundle
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A candidate without its demo wrapper was accepted' >&2; exit 1
fi
echo 'GPU profile checks the DEB, tar and AppImage wrappers and rejects invalid candidates'
