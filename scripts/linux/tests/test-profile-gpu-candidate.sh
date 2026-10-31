#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bundle/usr/bin" "$work/bundle/usr/lib/accelerantgine" "$work/artifacts" "$work/bin"
cat > "$work/bundle/usr/bin/AccelerANTgine_demo" <<'STUB'
#!/usr/bin/env bash
[[ ( "$1" == --onnx-only || "$1" == --video-check ) && "$2" == --model && "$4" == --device && "$6" == --profile ]]
[[ "$LD_LIBRARY_PATH" == "$TEST_SDK_PATH" && -z "${GST_PLUGIN_PATH+x}" && -z "${GST_PLUGIN_PATH_1_0+x}" ]]
[[ -z "${GST_PLUGIN_SYSTEM_PATH_1_0+x}" && -z "${GST_REGISTRY+x}" && -z "${GST_PLUGIN_SCANNER+x}" ]]
[[ "$GST_REGISTRY_1_0" == "$RUNNER_TEMP"/accelerantgine-profile.*/gst-registry.bin ]]
printf '%s %s\n' "$1" "$5" >> "${TEST_DEMO_LOG:?}"
printf '[]\n' > "$7.json"
STUB
cat > "$work/bundle/usr/lib/accelerantgine/AccelerANTgine_demo" <<'STUB'
#!/usr/bin/env bash
echo 'The library binary bypasses the packaged wrapper' >&2
exit 1
STUB
cat > "$work/bin/python3" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -I && "$2" == */verify_ort_profile.py && -f "$3" && "$4" == --device && "$5" == cuda ]]
if [[ ${FAIL_VIDEO_PROFILE:-0} == 1 && "$3" == */video-profile* ]]; then exit 1; fi
STUB
chmod +x "$work/bundle/usr/bin/AccelerANTgine_demo" "$work/bundle/usr/lib/accelerantgine/AccelerANTgine_demo" "$work/bin/python3"
tar -czf "$work/artifacts/candidate.tar.gz" -C "$work" bundle
export PATH="$work/bin:$PATH" TEST_DEMO_LOG="$work/demo.log" RUNNER_TEMP="$work"
export LD_LIBRARY_PATH="$work/gpu-sdk" TEST_SDK_PATH="$work/gpu-sdk"
export GST_PLUGIN_PATH="$work/host-plugin" GST_PLUGIN_PATH_1_0="$work/host-plugin"
export GST_PLUGIN_SYSTEM_PATH_1_0="$work/host-system" GST_REGISTRY="$work/host-registry" GST_PLUGIN_SCANNER="$work/host-scanner"
bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda
[[ "$(cat "$TEST_DEMO_LOG")" == $'--onnx-only cuda\n--video-check cuda' ]]
if FAIL_VIDEO_PROFILE=1 bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A rejected video profile was accepted' >&2; exit 1
fi
rm "$work/bundle/usr/bin/AccelerANTgine_demo"
tar -czf "$work/artifacts/candidate.tar.gz" -C "$work" bundle
if bash "$repo/scripts/linux/profile-gpu-candidate.sh" "$work/artifacts" "$work/model.onnx" cuda >/dev/null 2>&1; then
  echo 'A candidate without its demo wrapper was accepted' >&2; exit 1
fi
echo 'GPU profile selects the packaged wrapper and rejects a missing wrapper'
