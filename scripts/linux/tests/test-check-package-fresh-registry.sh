#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
repo=$SUITE_ROOT work=$SUITE_WORK
check="$repo/scripts/linux/check-package-fresh-registry.sh"
stubs="$work/stubs"
packages="$work/packages"
tree="$work/tree/pkg"
mkdir -p "$stubs" "$packages" "$tree/usr/bin" "$tree/usr/lib/accelerantgine/gstreamer-1.0"
touch "$tree/usr/lib/accelerantgine/gstreamer-1.0/libgstrswebrtc.so" "$tree/usr/lib/accelerantgine/gstreamer-1.0/libgstvpx.so"
cat > "$tree/usr/bin/AccelerANTgine" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == --gst_check ]]; then
  [[ ${GST_DEBUG:-} == GST_REGISTRY:5 ]]
  [[ ${BAD_CHECK:-} != 1 ]] || exit 1
  [[ ${BAD_SCAN:-} == 1 ]] || echo 'Using scan-helper to load plugin x'
  exit 0
fi
[[ ${BAD_LOG:-} != 1 ]] || echo "${BAD_LOG_TEXT:-No codec available}"
[[ ${BAD_BUNDLED:-} != 1 || -z ${KATAGLYPHIS_BUNDLED_GLIBC:-} ]] || exit 1
[[ ${BAD_STATUS:-} != 1 ]] || exit 1
exit 124
STUB
chmod +x "$tree/usr/bin/AccelerANTgine"
tar -czf "$packages/app.tar.gz" -C "$work/tree" pkg
touch "$packages/app.deb"
cat > "$packages/app.AppImage" <<STUB
#!/usr/bin/env bash
mkdir squashfs-root && cp -a "$tree/." squashfs-root/
STUB
chmod +x "$packages/app.AppImage"
cat > "$stubs/dpkg-deb" <<STUB
#!/usr/bin/env bash
cp -a "$tree/." "\$3/"
STUB
for tool in mount umount; do printf '#!/usr/bin/env bash\n' > "$stubs/$tool"; done
printf '#!/usr/bin/env bash\necho 0\n' > "$stubs/id"
printf '#!/usr/bin/env bash\nshift 3\nexec "$@"\n' > "$stubs/timeout"
# Readdir order is the filesystem's, so the listing is what the fixture decides.
cat > "$stubs/find" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -printf "* ]]; then
  if [[ ${BAD_ORDER:-} == 1 ]]; then echo libgstvpx.so; else echo libgstrswebrtc.so; fi
  exit 0
fi
[[ " $* " != *" -delete "* ]] || exit 0
exec /usr/bin/find "$@"
STUB
cat > "$stubs/gst-webrtc-signalling-server" <<'STUB'
#!/usr/bin/env bash
exec python3 -I -c 'import socket, time, sys; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(120)' "$4"
STUB
chmod +x "$stubs"/*

# Parallel mutation workers run this suite side by side, so a shared port would fail every case for the wrong reason.
port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
run_check() { PATH="$stubs:$PATH" bash "$check" "$packages" "$port" > "$work/out" 2>&1; }
# Usage: refuses_with MESSAGE WHAT [VAR=VALUE]...; any other failure must not satisfy the case.
refuses_with() {
  local message=$1 what=$2 rc=0
  shift 2
  env "$@" PATH="$stubs:$PATH" bash "$check" "$packages" "$port" > "$work/out" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]] && grep -Fq -e "$message" "$work/out"; then echo "ok: $what"; return 0; fi
  fail "$what: exit $rc, expected a failure naming '$message'"
  cat "$work/out" >&2
}

suite_expect pass 'finished packages that stream on both loaders pass' run_check
grep -Fq 'appimage (bundled): a fresh registry' "$work/out" || fail 'the AppImage bundled run did not report'
grep -Fq 'tarball (host): a fresh registry' "$work/out" || fail 'the tarball host run did not report'
refuses_with '--gst_check failed' 'a failed --gst_check fails' BAD_CHECK=1
refuses_with 'not written through the packaged scanner' 'a registry not written through the scanner fails' BAD_SCAN=1
refuses_with 'did not stream' 'an empty codec list fails even when the process survives' BAD_LOG=1
refuses_with 'did not stream (status 1)' 'a stream that ended early fails' BAD_STATUS=1
refuses_with '(bundled): a fresh registry did not stream' 'only the bundled loader failing still fails' BAD_BUNDLED=1
refuses_with 'list libgstrswebrtc.so first' 'a directory that cannot list the plugin first fails' BAD_ORDER=1
refuses_with 'did not stream' 'a scanner fallback during the stream fails' BAD_LOG=1 BAD_LOG_TEXT='External plugin loader failed'
mv "$packages/app.AppImage" "$work/held"
refuses_with 'Expected one .deb' 'a missing package format fails'
mv "$work/held" "$packages/app.AppImage"
printf '#!/usr/bin/env bash\necho 1000\n' > "$stubs/id"
refuses_with 'needs root' 'a non-root run fails'
suite_finish 'fresh-registry'
echo 'fresh-registry package check verdicts passed'
