#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="${repo}/scripts/linux/verify-package-hardening.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
failures=0

cat > "${work}/fixture.c" <<'C'
#include <stdio.h>
#include <string.h>
int fixture(const char *text) {
  char buffer[32];
  strcpy(buffer, text);
  printf("%s\n", buffer);
  return (int)strlen(buffer);
}
#ifdef FIXTURE_MAIN
int main(int argc, char **argv) { return fixture(argc > 1 ? argv[1] : "fixture"); }
#endif
C

# Explicit on both sides, so a distro compiler default can neither add nor remove a property.
hardened=(-O2 -fstack-protector-all -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -Wl,-z,relro -Wl,-z,now)
build() {
  local out="$1" kind="$2"
  shift 2
  if [[ "$kind" == executable ]]; then
    cc -DFIXTURE_MAIN -fPIE -pie "${hardened[@]}" "$@" -o "$out" "${work}/fixture.c"
  else
    cc -shared -fPIC "${hardened[@]}" "$@" -o "$out" "${work}/fixture.c"
  fi
}

# Lays out what CPack ships: launcher scripts in usr/bin, the ELFs beside the bundled loader.
package() {
  local dir="$1" cli="$2" demo="$3" lib="$4" tree
  rm -rf -- "$dir"
  mkdir -p "$dir"
  for tree in "${work}/tree-deb" "${work}/tree-tar/AccelerANTgine-0-Linux"; do
    rm -rf -- "$tree"
    mkdir -p "$tree/usr/bin" "$tree/usr/lib/accelerantgine"
    printf '#!/bin/sh\nexec true\n' > "$tree/usr/bin/AccelerANTgine"
    printf '#!/bin/sh\nexec true\n' > "$tree/usr/bin/AccelerANTgine_demo"
    chmod +x "$tree/usr/bin/AccelerANTgine" "$tree/usr/bin/AccelerANTgine_demo"
    cp "$cli" "$tree/usr/lib/accelerantgine/AccelerANTgine"
    cp "$demo" "$tree/usr/lib/accelerantgine/AccelerANTgine_demo"
    cp "$lib" "$tree/usr/lib/libAccelerANTgine.so"
  done
  mkdir -p "${work}/tree-deb/DEBIAN"
  printf 'Package: fixture\nVersion: 0\nArchitecture: all\nMaintainer: t <t@example.invalid>\nDescription: t\n' \
    > "${work}/tree-deb/DEBIAN/control"
  dpkg-deb --build --root-owner-group "${work}/tree-deb" "$dir/fixture.deb" > /dev/null
  tar -czf "$dir/fixture.tar.gz" -C "${work}/tree-tar" AccelerANTgine-0-Linux
}

expect() {
  local verdict="$1" name="$2" dir="$3" pattern="${4:-}" log="${work}/gate.log" rc=0
  bash "$gate" "$dir" > "$log" 2>&1 || rc=$?
  if [[ "$verdict" == pass && $rc -ne 0 ]]; then
    printf 'FAIL %s: the gate refused hardened packages\n' "$name" >&2; cat "$log" >&2; failures=$((failures + 1))
  elif [[ "$verdict" == fail && $rc -ne 1 ]]; then
    printf 'FAIL %s: the gate returned %s, not 1\n' "$name" "$rc" >&2; cat "$log" >&2; failures=$((failures + 1))
  elif [[ -n "$pattern" ]] && ! grep -q -e "$pattern" "$log"; then
    printf 'FAIL %s: the gate did not report %s\n' "$name" "$pattern" >&2; cat "$log" >&2; failures=$((failures + 1))
  else
    printf 'ok %s\n' "$name"
  fi
}

# A mutant fixture that still carries the dropped property would make its case prove nothing.
require_absent() {
  local file="$1" pattern="$2" what="$3"
  if readelf -dW --dyn-syms -hlW "$file" | grep -Eq -e "$pattern"; then
    printf 'FAIL fixture %s still shows %s\n' "${file##*/}" "$what" >&2
    exit 1
  fi
}

bin="${work}/bin"
mkdir -p "$bin"
build "$bin/cli" executable
build "$bin/lib.so" library
build "$bin/cli-no-pie" executable -fno-pie -no-pie
build "$bin/cli-lazy" executable -Wl,-z,lazy
build "$bin/cli-no-ssp" executable -fno-stack-protector
build "$bin/cli-no-fortify" executable -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
build "$bin/lib-lazy.so" library -Wl,-z,lazy
build "$bin/lib-no-ssp.so" library -fno-stack-protector
build "$bin/lib-no-fortify.so" library -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
require_absent "$bin/cli-no-pie" 'Type: +DYN' 'ELF type DYN'
require_absent "$bin/cli-lazy" 'BIND_NOW|\(FLAGS_1\).*\bNOW\b' 'BIND_NOW'
require_absent "$bin/lib-lazy.so" 'BIND_NOW|\(FLAGS_1\).*\bNOW\b' 'BIND_NOW'
require_absent "$bin/cli-no-ssp" '__stack_chk_fail' '__stack_chk_fail'
require_absent "$bin/lib-no-ssp.so" '__stack_chk_fail' '__stack_chk_fail'
require_absent "$bin/cli-no-fortify" '__(strcpy|printf|memcpy)_chk' 'a __*_chk import'
require_absent "$bin/lib-no-fortify.so" '__(strcpy|printf|memcpy)_chk' 'a __*_chk import'

package "${work}/good" "$bin/cli" "$bin/cli" "$bin/lib.so"
expect pass 'hardened packages' "${work}/good"
package "${work}/p1" "$bin/cli-no-pie" "$bin/cli" "$bin/lib.so"
expect fail 'executable without PIE' "${work}/p1" 'not PIE'
package "${work}/p1b" "$bin/lib.so" "$bin/cli" "$bin/lib.so"
expect fail 'shared library shipped as the executable' "${work}/p1b" 'AccelerANTgine: not PIE'
package "${work}/p2" "$bin/cli-lazy" "$bin/cli" "$bin/lib.so"
expect fail 'executable without BIND_NOW' "${work}/p2" 'AccelerANTgine: no BIND_NOW'
package "${work}/p3" "$bin/cli-no-ssp" "$bin/cli" "$bin/lib.so"
expect fail 'executable without stack protector' "${work}/p3" 'no __stack_chk_fail'
package "${work}/p4" "$bin/cli-no-fortify" "$bin/cli" "$bin/lib.so"
expect fail 'executable without fortify' "${work}/p4" 'no __\*_chk'
package "${work}/p5" "$bin/cli" "$bin/cli-lazy" "$bin/lib.so"
expect fail 'demo without BIND_NOW' "${work}/p5" 'AccelerANTgine_demo: no BIND_NOW'
package "${work}/p5b" "$bin/cli" "$bin/cli-no-ssp" "$bin/lib.so"
expect fail 'demo without stack protector' "${work}/p5b" 'AccelerANTgine_demo: no __stack_chk_fail'
package "${work}/p5c" "$bin/cli" "$bin/cli-no-fortify" "$bin/lib.so"
expect pass 'demo without fortify' "${work}/p5c"
package "${work}/p6" "$bin/cli" "$bin/cli" "$bin/lib-lazy.so"
expect fail 'library without BIND_NOW' "${work}/p6" 'libAccelerANTgine.so: no BIND_NOW'
package "${work}/p7" "$bin/cli" "$bin/cli" "$bin/lib-no-ssp.so"
expect fail 'library without stack protector' "${work}/p7" 'libAccelerANTgine.so: no __stack_chk_fail'
package "${work}/p8" "$bin/cli" "$bin/cli" "$bin/lib-no-fortify.so"
expect fail 'library without fortify' "${work}/p8" 'libAccelerANTgine.so: no __\*_chk'

package "${work}/p9" "$bin/cli" "$bin/cli" "$bin/lib.so"
rm -- "${work}/p9/fixture.tar.gz"
expect fail 'missing tarball' "${work}/p9" 'no .tar.gz'
package "${work}/p10" "$bin/cli" "$bin/cli" "$bin/lib.so"
rm -- "${work}/p10/fixture.deb"
expect fail 'missing DEB' "${work}/p10" 'no .deb'
package "${work}/p11" "$bin/cli" "$bin/cli" "$bin/lib.so"
cp "${work}/p1/fixture.tar.gz" "${work}/p11/fixture.tar.gz"
expect fail 'hardened DEB beside an unhardened tarball' "${work}/p11" 'fixture.tar.gz/AccelerANTgine: not PIE'
package "${work}/p12" "$bin/cli" "$bin/cli" "$bin/lib.so"
printf '#!/bin/sh\n' > "${work}/tree-deb/usr/lib/accelerantgine/AccelerANTgine"
dpkg-deb --build --root-owner-group "${work}/tree-deb" "${work}/p12/fixture.deb" > /dev/null
expect fail 'executable replaced by a script' "${work}/p12" 'not exactly one ELF named AccelerANTgine$'

if [[ $failures -gt 0 ]]; then
  printf '%d package hardening case(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'package hardening gate: all cases passed\n'
