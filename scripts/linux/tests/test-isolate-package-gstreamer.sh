#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
mkdir "$SUITE_WORK/bin"
for name in AccelerANTgine AccelerANTgine_demo; do
  cat > "$SUITE_WORK/bin/$name" <<'STUB'
#!/bin/bash
for name in GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_SYSTEM_PATH_1_0 GST_PLUGIN_SCANNER GST_PLUGIN_SCANNER_1_0 GST_REGISTRY GST_REGISTRY_1_0 GST_REGISTRY_FORK; do
  [[ -z ${!name+x} ]] || { echo "inherited $name" >&2; exit 1; }
done
[[ ${LD_LIBRARY_PATH:-} == /gpu/sdk && ${OTHER_SETTING:-} == keep ]]
STUB
  chmod 755 "$SUITE_WORK/bin/$name"
done
helper="$SUITE_ROOT/scripts/linux/isolate-package-gstreamer.sh"
bash "$helper" "$SUITE_WORK/bin" AccelerANTgine AccelerANTgine_demo
bash "$helper" "$SUITE_WORK/bin" AccelerANTgine AccelerANTgine_demo
for name in AccelerANTgine AccelerANTgine_demo; do
  [[ $(grep -c '^# AccelerANTgine packaged GStreamer isolation$' "$SUITE_WORK/bin/$name") == 1 ]]
  env GST_PLUGIN_PATH=/host GST_PLUGIN_PATH_1_0=/host GST_PLUGIN_SYSTEM_PATH=/host \
    GST_PLUGIN_SYSTEM_PATH_1_0=/host GST_PLUGIN_SCANNER=/host GST_PLUGIN_SCANNER_1_0=/host \
    GST_REGISTRY=/host GST_REGISTRY_1_0=/host GST_REGISTRY_FORK=yes LD_LIBRARY_PATH=/gpu/sdk \
    OTHER_SETTING=keep "$SUITE_WORK/bin/$name"
done
rm "$SUITE_WORK/bin/AccelerANTgine_demo"
if bash "$helper" "$SUITE_WORK/bin" AccelerANTgine_demo >/dev/null 2>&1; then echo 'Accepted a missing launcher' >&2; exit 1; fi
ln -s AccelerANTgine "$SUITE_WORK/bin/AccelerANTgine_demo"
if bash "$helper" "$SUITE_WORK/bin" AccelerANTgine_demo >/dev/null 2>&1; then echo 'Accepted a symlink launcher' >&2; exit 1; fi
echo 'Packaged launcher GStreamer isolation passed'
