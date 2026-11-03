#!/usr/bin/env bash
# Runs as root in the image: each finished package streams from a fresh registry listing webrtcsink's plugin first; other scan orders stay unproved.
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { echo 'usage: check-package-fresh-registry.sh PACKAGE_DIR [SIGNALLING_PORT]' >&2; exit 2; }
package_dir="$(realpath -e "$1")"
[[ $(id -u) -eq 0 ]] || { echo 'Mounting the plugin directory needs root' >&2; exit 1; }
command -v gst-webrtc-signalling-server > /dev/null || { echo 'gst-webrtc-signalling-server is not on PATH' >&2; exit 1; }

first=libgstrswebrtc.so
port=${2:-18445}
work="$(mktemp -d "${TMPDIR:-/tmp}/accelerantgine-registry.XXXXXXXX")"
signalling=""
mounted=""
cleanup() {
  [[ -z $signalling ]] || { kill "$signalling" 2>/dev/null || true; wait "$signalling" 2>/dev/null || true; }
  [[ -z $mounted ]] || umount "$mounted"
  rm -rf -- "$work"
}
trap cleanup EXIT

# A tmpfs lists entries newest-first or oldest-first depending on the kernel, so both copy orders are tried.
fill_listing_first() {
  local plugins=$1 saved=$2 pass file listing
  for pass in first last; do
    find "$plugins" -mindepth 1 -delete
    [[ $pass == last ]] || cp "$saved/$first" "$plugins/"
    for file in "$saved"/*.so; do
      [[ ${file##*/} == "$first" ]] || cp "$file" "$plugins/"
    done
    [[ $pass == first ]] || cp "$saved/$first" "$plugins/"
    # Read whole, not through head: a closed pipe would fail this under pipefail.
    listing="$(find "$plugins" -mindepth 1 -maxdepth 1 -printf '%f\n')"
    [[ ${listing%%$'\n'*} != "$first" ]] || return 0
  done
  echo "Cannot make $plugins list $first first" >&2
  return 1
}

start_signalling() {
  local attempt
  gst-webrtc-signalling-server --host 127.0.0.1 --port "$port" > "$work/signalling.log" 2>&1 &
  signalling=$!
  for ((attempt = 0; attempt < 50; attempt++)); do
    sleep 0.2
    if ! kill -0 "$signalling" 2>/dev/null; then
      cat "$work/signalling.log" >&2
      echo 'The signalling server exited before it listened' >&2
      return 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
  done
  echo 'The signalling server did not listen within 10 s' >&2
  return 1
}

# Usage: check_runtime NAME CLI host|bundled; both loaders, because the scanner must start under whichever one the launcher picks.
check_runtime() {
  local name=$1 cli=$2 mode=$3 log="$work/$1-$3.log" status=0
  local -a runtime=(env -u LD_LIBRARY_PATH -u LD_PRELOAD -u KATAGLYPHIS_BUNDLED_GLIBC)
  [[ $mode != bundled ]] || runtime+=(KATAGLYPHIS_BUNDLED_GLIBC=1)
  if ! "${runtime[@]}" XDG_CACHE_HOME="$work/$name-$mode-check" GST_DEBUG=GST_REGISTRY:5 "$cli" --gst_check > "$log" 2>&1; then
    tail -n 40 "$log" >&2
    echo "$name ($mode): --gst_check failed" >&2
    return 1
  fi
  if ! grep -Fq 'Using scan-helper to load plugin' "$log"; then
    echo "$name ($mode): the registry was not written through the packaged scanner" >&2
    return 1
  fi
  "${runtime[@]}" XDG_CACHE_HOME="$work/$name-$mode-stream" timeout -s INT 8 "$cli" --webrtc --source test \
    --server="ws://127.0.0.1:$port" > "$log" 2>&1 < /dev/null || status=$?
  # 124 is the timeout: the stream was still up when it was stopped.
  if [[ $status -ne 124 ]] || grep -Eq 'No codec available|External plugin loader failed' "$log"; then
    tail -n 40 "$log" >&2
    echo "$name ($mode): a fresh registry did not stream (status $status)" >&2
    return 1
  fi
  echo "$name ($mode): a fresh registry listing $first first streams"
}

check_tree() {
  local name=$1 root=$2 plugins="$2/usr/lib/accelerantgine/gstreamer-1.0" saved="$work/$1-plugins" mode
  [[ -x $root/usr/bin/AccelerANTgine ]] || { echo "$name: the CLI is missing" >&2; return 1; }
  [[ -f $plugins/$first ]] || { echo "$name: $first is missing" >&2; return 1; }
  mkdir "$saved"
  cp "$plugins"/*.so "$saved/"
  mount -t tmpfs -o size=2g tmpfs "$plugins"
  mounted=$plugins
  fill_listing_first "$plugins" "$saved"
  for mode in host bundled; do check_runtime "$name" "$root/usr/bin/AccelerANTgine" "$mode"; done
  umount "$plugins"
  mounted=""
}

shopt -s nullglob
debs=("$package_dir"/*.deb)
tarballs=("$package_dir"/*.tar.gz)
appimages=("$package_dir"/*.AppImage)
shopt -u nullglob
[[ ${#debs[@]} -eq 1 && ${#tarballs[@]} -eq 1 && ${#appimages[@]} -eq 1 ]] ||
  { echo "Expected one .deb, one .tar.gz and one .AppImage in $package_dir" >&2; exit 1; }

start_signalling
mkdir "$work/deb" "$work/tarball" "$work/appimage"
dpkg-deb -x "${debs[0]}" "$work/deb"
check_tree deb "$work/deb"
tar -xzf "${tarballs[0]}" -C "$work/tarball" --strip-components=1
check_tree tarball "$work/tarball"
(cd "$work/appimage" && "${appimages[0]}" --appimage-extract > /dev/null)
check_tree appimage "$work/appimage/squashfs-root"
