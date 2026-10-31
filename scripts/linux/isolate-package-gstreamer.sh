#!/usr/bin/env bash
# Installed executables use the GStreamer plugins shipped with this package.
set -euo pipefail

[[ $# -ge 2 ]] || { echo 'usage: isolate-package-gstreamer.sh INSTALLED_BIN_DIR LAUNCHER...' >&2; exit 2; }
bin_dir=$1
shift
marker='# AccelerANTgine packaged GStreamer isolation'
for name in "$@"; do
  [[ $name == AccelerANTgine || $name == AccelerANTgine_demo ]] || { echo "Unexpected launcher: $name" >&2; exit 1; }
  file="$bin_dir/$name"
  [[ -f $file && ! -L $file ]] || { echo "Expected packaged launcher: $file" >&2; exit 1; }
  IFS= read -r first < "$file"
  [[ $first == '#!/bin/bash' ]] || { echo "Not a generated Bash launcher: $file" >&2; exit 1; }
  if grep -Fxq "$marker" "$file"; then continue; fi
  temp="$(mktemp "$bin_dir/.${name}.XXXXXXXX")"
  trap 'rm -f -- "$temp"' EXIT
  {
    IFS= read -r first
    printf '%s\n' "$first" "$marker"
    printf '%s\n' 'unset GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_SYSTEM_PATH_1_0 GST_PLUGIN_SCANNER GST_PLUGIN_SCANNER_1_0 GST_REGISTRY GST_REGISTRY_1_0 GST_REGISTRY_FORK'
    cat
  } < "$file" > "$temp"
  chmod --reference="$file" "$temp"
  mv -f -- "$temp" "$file"
  trap - EXIT
done
