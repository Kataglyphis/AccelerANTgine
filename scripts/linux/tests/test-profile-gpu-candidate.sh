#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
repo=$SUITE_ROOT work=$SUITE_WORK
hub=${1:-"$repo/third_party/ANTfrastructure"}
mkdir -p "$work/bundle/usr/bin" "$work/bundle/usr/lib/accelerantgine" "$work/bundle/usr/share/accelerantgine/models" "$work/artifacts" "$work/bin" "$work/repo/scripts/linux"
mkdir -p "$work/repo/third_party/ANTfrastructure/linux/scripts/lib" "$work/repo/scripts/linux/lib"
cp "$repo/scripts/linux/lib/detector-evidence.sh" "$work/repo/scripts/linux/lib/"
cp "$hub/linux/scripts/lib/gpu-profile-env.sh" "$hub/linux/scripts/lib/log-bootstrap.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/"
profile="$work/repo/scripts/linux/profile-gpu-candidate.sh"
cp "$repo/scripts/linux/profile-gpu-candidate.sh" "$profile"
printf 'packaged model\n' >"$work/bundle/usr/share/accelerantgine/models/deim_dfine_n_coco.onnx"
cat >"$work/repo/scripts/linux/check-gpu-detector-parity.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 && "$3" == cuda && -f "$2" && "$2" == */usr/share/accelerantgine/models/deim_dfine_n_coco.onnx ]]
case "$1" in
  */tar/*) kind=tar ;;
  */appimage/squashfs-root/*) kind=appimage ;;
  */deb/*) kind=deb ;;
  *) exit 1 ;;
esac
[[ "$2" == *"/$kind"* || "$kind" == appimage ]]
[[ "$4" == "$RUNNER_TEMP"/accelerantgine-profile.*/"$kind"-detector-parity ]]
printf '%s parity\n' "$kind" >>"${TEST_DEMO_LOG:?}"
[[ "${FAIL_PARITY_KIND:-}" != "$kind" ]]
STUB
cat > "$work/bundle/usr/bin/AccelerANTgine_demo" <<'STUB'
#!/usr/bin/env bash
set -e
if [[ "$1" == --onnx-only ]]; then
  [[ $# -eq 3 && "$2" == --profile ]]
  profile="$3"
  mode=default
else
  [[ "$1" == --video-check && $# -eq 7 && "$2" == --model && "$3" == "$TEST_MODEL" && "$4" == --device && "$6" == --profile ]]
  profile="$7"
  mode="$5"
fi
[[ "$LD_LIBRARY_PATH" == "$TEST_SDK_PATH" && -z "${GST_PLUGIN_PATH+x}" && -z "${GST_PLUGIN_PATH_1_0+x}" ]]
[[ -z "${LD_PRELOAD+x}" && -z "${LD_AUDIT+x}" ]]
[[ -z "${MIGRAPHX_SKIP_BENCHMARKING+x}" && -z "${ORT_MIGRAPHX_MODEL_CACHE_PATH+x}" && -z "${MIGRAPHX_UNKNOWN+x}" ]]
[[ -z "${ORT_AMDGPU_EP_ROOT+x}" ]]
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
export MIGRAPHX_SKIP_BENCHMARKING=poison ORT_MIGRAPHX_MODEL_CACHE_PATH=poison MIGRAPHX_UNKNOWN=poison
export ORT_AMDGPU_EP_ROOT="$work/image-plugin-root"
export GST_PLUGIN_PATH="$work/host-plugin" GST_PLUGIN_PATH_1_0="$work/host-plugin"
export GST_PLUGIN_SYSTEM_PATH_1_0="$work/host-system" GST_REGISTRY="$work/host-registry" GST_PLUGIN_SCANNER="$work/host-scanner"
mv "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh" "$work/gpu-profile-env.sh"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'Missing GPU environment helper was accepted' >&2; exit 1
fi
printf '# No GPU environment API\n' > "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'GPU environment helper without its API was accepted' >&2; exit 1
fi
mv "$work/gpu-profile-env.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/gpu-profile-env.sh"
mv "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh" "$work/log-bootstrap.sh"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'Missing GPU environment logging bootstrap was accepted' >&2; exit 1
fi
mv "$work/log-bootstrap.sh" "$work/repo/third_party/ANTfrastructure/linux/scripts/lib/log-bootstrap.sh"
bash "$profile" "$work/artifacts" "$work/model.onnx" cuda
[[ "$(cat "$TEST_DEMO_LOG")" == $'tar --onnx-only default\ntar --video-check cuda\ntar parity\nappimage --onnx-only default\nappimage --video-check cuda\nappimage parity\ndeb --onnx-only default\ndeb --video-check cuda\ndeb parity' ]] || {
  echo 'Expected direct and video profiling from every package' >&2; exit 1;
}
for kind in tar appimage deb; do
  if FAIL_PARITY_KIND="$kind" bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
    echo "Rejected $kind detector parity was accepted" >&2; exit 1
  fi
done
if FAIL_DEFAULT_PROFILE=1 bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected default-device profile was accepted' >&2; exit 1
fi
if FAIL_VIDEO_PROFILE=1 bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected video profile was accepted' >&2; exit 1
fi
if FAIL_APPIMAGE_PROFILE=1 bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected AppImage profile was accepted' >&2; exit 1
fi
if FAIL_DEB_PROFILE=1 bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected DEB profile was accepted' >&2; exit 1
fi
if FAIL_DEB_VIDEO_PROFILE=1 bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected DEB video profile was accepted' >&2; exit 1
fi
if FAIL_APPIMAGE_EXTRACT=1 bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A failed AppImage extraction was accepted' >&2; exit 1
fi
mv "$work/artifacts/candidate.AppImage" "$work/candidate.AppImage"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A missing AppImage was accepted' >&2; exit 1
fi
mv "$work/candidate.AppImage" "$work/artifacts/candidate.AppImage"
cp "$work/artifacts/candidate.AppImage" "$work/artifacts/duplicate.AppImage"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'Duplicate AppImages were accepted' >&2; exit 1
fi
rm "$work/artifacts/duplicate.AppImage"
mv "$work/artifacts/candidate.deb" "$work/candidate.deb"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A missing DEB was accepted' >&2; exit 1
fi
mv "$work/candidate.deb" "$work/artifacts/candidate.deb"
cp "$work/artifacts/candidate.deb" "$work/artifacts/duplicate.deb"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'Duplicate DEBs were accepted' >&2; exit 1
fi
rm "$work/artifacts/duplicate.deb"
mv "$work/artifacts/candidate.deb" "$work/candidate.deb"
printf 'not a DEB' > "$work/artifacts/candidate.deb"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A corrupt DEB was accepted' >&2; exit 1
fi
rm "$work/artifacts/candidate.deb"
rm "$work/deb-package/usr/bin/AccelerANTgine_demo"
ln -s ../../lib/accelerantgine/AccelerANTgine_demo "$work/deb-package/usr/bin/AccelerANTgine_demo"
dpkg-deb --build --root-owner-group "$work/deb-package" "$work/artifacts/candidate.deb" >/dev/null
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A DEB with a linked demo wrapper was accepted' >&2; exit 1
fi
mv "$work/candidate.deb" "$work/artifacts/candidate.deb"
rm "$work/appimage-tree/usr/bin/AccelerANTgine_demo"
ln -s ../../lib/accelerantgine/AccelerANTgine_demo "$work/appimage-tree/usr/bin/AccelerANTgine_demo"
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'An AppImage with a linked demo wrapper was accepted' >&2; exit 1
fi
rm "$work/bundle/usr/bin/AccelerANTgine_demo"
tar -czf "$work/artifacts/candidate.tar.gz" -C "$work" bundle
if bash "$profile" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A candidate without its demo wrapper was accepted' >&2; exit 1
fi
echo 'GPU profile checks the DEB, tar and AppImage wrappers and rejects invalid candidates'
