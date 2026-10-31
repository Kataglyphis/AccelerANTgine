#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
for name in AccelerANTgine AccelerANTgine_demo; do
  cat > "$work/bin/$name" <<'STUB'
#!/bin/bash
for name in GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_SYSTEM_PATH_1_0 GST_PLUGIN_SCANNER GST_PLUGIN_SCANNER_1_0 GST_REGISTRY GST_REGISTRY_1_0 GST_REGISTRY_FORK; do
  [[ -z ${!name+x} ]] || { echo "inherited $name" >&2; exit 1; }
done
[[ ${LD_LIBRARY_PATH:-} == /gpu/sdk && ${OTHER_SETTING:-} == keep ]]
STUB
  chmod 755 "$work/bin/$name"
done
helper="$repo/scripts/linux/isolate-package-gstreamer.sh"
bash "$helper" "$work/bin" AccelerANTgine AccelerANTgine_demo
bash "$helper" "$work/bin" AccelerANTgine AccelerANTgine_demo
for name in AccelerANTgine AccelerANTgine_demo; do
  [[ $(grep -c '^# AccelerANTgine packaged GStreamer isolation$' "$work/bin/$name") == 1 ]]
  env GST_PLUGIN_PATH=/host GST_PLUGIN_PATH_1_0=/host GST_PLUGIN_SYSTEM_PATH=/host \
    GST_PLUGIN_SYSTEM_PATH_1_0=/host GST_PLUGIN_SCANNER=/host GST_PLUGIN_SCANNER_1_0=/host \
    GST_REGISTRY=/host GST_REGISTRY_1_0=/host GST_REGISTRY_FORK=yes LD_LIBRARY_PATH=/gpu/sdk \
    OTHER_SETTING=keep "$work/bin/$name"
done
rm "$work/bin/AccelerANTgine_demo"
if bash "$helper" "$work/bin" AccelerANTgine_demo >/dev/null 2>&1; then echo 'Accepted a missing launcher' >&2; exit 1; fi
ln -s AccelerANTgine "$work/bin/AccelerANTgine_demo"
if bash "$helper" "$work/bin" AccelerANTgine_demo >/dev/null 2>&1; then echo 'Accepted a symlink launcher' >&2; exit 1; fi
echo 'Packaged launcher GStreamer isolation passed'
