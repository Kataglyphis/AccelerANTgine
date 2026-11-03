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

run_check() { PATH="$stubs:$PATH" bash "$check" "$packages" > "$work/out" 2>&1; }
with() { env "$1" bash -c "PATH='$stubs':\"\$PATH\" bash '$check' '$packages' > '$work/out' 2>&1"; }

suite_expect pass 'finished packages that stream on both loaders pass' run_check
grep -Fq 'appimage (bundled): a fresh registry' "$work/out" || fail 'the AppImage bundled run did not report'
grep -Fq 'tarball (host): a fresh registry' "$work/out" || fail 'the tarball host run did not report'
suite_expect fail 'a failed --gst_check fails' with BAD_CHECK=1
suite_expect fail 'a registry not written through the scanner fails' with BAD_SCAN=1
suite_expect fail 'an empty codec list fails even when the process survives' with BAD_LOG=1
suite_expect fail 'a stream that ended early fails' with BAD_STATUS=1
suite_expect fail 'only the bundled loader failing still fails' with BAD_BUNDLED=1
suite_expect fail 'a directory that cannot list the plugin first fails' with BAD_ORDER=1
export BAD_LOG_TEXT='External plugin loader failed'
suite_expect fail 'a scanner fallback during the stream fails' with BAD_LOG=1
unset BAD_LOG_TEXT
mv "$packages/app.AppImage" "$work/held"
suite_expect fail 'a missing package format fails' run_check
mv "$work/held" "$packages/app.AppImage"
printf '#!/usr/bin/env bash\necho 1000\n' > "$stubs/id"
suite_expect fail 'a non-root run fails' run_check
suite_finish 'fresh-registry'
echo 'fresh-registry package check verdicts passed'
