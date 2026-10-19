#!/usr/bin/env bash
# test-collect-release-assets.sh: collect-release-assets.sh against artifact trees shaped like the lanes' uploads.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
collect="${here}/../collect-release-assets.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fails=0
check() {
  if "${@:2}"; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

a="${work}/artifacts"
for pair in x64:x86_64 arm64:aarch64; do
  arch="${pair%%:*}" m="${pair##*:}"
  l="${a}/linux-packages-${arch}"
  mkdir -p "${l}" "${a}/python-wheels-${arch}/gil" "${a}/python-wheels-${arch}/free-threaded"
  for ext in deb tar.gz AppImage; do printf 'pkg' > "${l}/AccelerANTgine-0.0.1-Linux-${m}-Release-Clang-23.1.3.${ext}"; done
  printf 'flatpak' > "${l}/AccelerANTgine-0.0.1-linux.flatpak"
  printf 'whl' > "${a}/python-wheels-${arch}/gil/kataglyphis_inference-0.0.1-cp314-cp314-linux_${m}.whl"
  printf 'whl' > "${a}/python-wheels-${arch}/free-threaded/kataglyphis_inference-0.0.1-cp314-cp314t-linux_${m}.whl"
done
for pair in x64:x86_64:x64 arm64:aarch64:arm64; do
  arch="${pair%%:*}" rest="${pair#*:}"; m="${rest%%:*}" msix="${rest##*:}"
  w="${a}/AccelerANTgine-windows-${arch}"
  mkdir -p "${w}/packages" "${w}/msix" "${w}/bundle/bin" "${w}/bundle/lib"
  for ext in msi zip; do printf 'pkg' > "${w}/packages/AccelerANTgine-0.0.1-Release-${m}.${ext}"; done
  printf 'msix' > "${w}/msix/AccelerANTgine_0.0.1.0_${msix}.msix"
  printf 'exe' > "${w}/bundle/bin/AccelerANTgine.exe"
  printf 'dll' > "${w}/bundle/lib/gst.dll"
done
printf 'nsis' > "${a}/AccelerANTgine-windows-x64/packages/AccelerANTgine-0.0.1-Release-x86_64.exe"
mkdir -p "${a}/AccelerANTgine-windows-arm64-tests/packages"
printf 'msi' > "${a}/AccelerANTgine-windows-arm64-tests/packages/tests.msi"
for site in accelerantgine-docs-site docs-site-docs; do
  mkdir -p "${a}/${site}/_downloads"
  printf 'zip' > "${a}/${site}/_downloads/examples.zip"
done

out="${work}/release"
check "it collects" bash "${collect}" "${a}" "${out}"
check "the Linux packages of both arches" test "$(find "${out}" -maxdepth 1 -name '*Linux*' | wc -l)" = 6
check "each flatpak named for its arch" test -e "${out}/AccelerANTgine-0.0.1-linux-x86_64.flatpak" -a -e "${out}/AccelerANTgine-0.0.1-linux-aarch64.flatpak"
check "all four wheels, gil and free-threaded" test "$(find "${out}" -maxdepth 1 -name '*.whl' | wc -l)" = 4
check "the MSI, zip and MSIX of both Windows arches" test "$(find "${out}" -maxdepth 1 \( -name '*.msi' -o -name '*.msix' -o -name '*.zip' \) | wc -l)" = 6
check "the x64 installer, but no exe from a bundle" bash -c "test -e '${out}/AccelerANTgine-0.0.1-Release-x86_64.exe' && ! test -e '${out}/AccelerANTgine.exe'"
check "nothing from a test artifact" test ! -e "${out}/tests.msi"
check "nothing from either docs site" test ! -e "${out}/examples.zip"
check "relative paths, as release.yml passes them" bash -c "cd '${work}' && bash '${collect}' artifacts release-relative >/dev/null && test -e release-relative/AccelerANTgine_0.0.1.0_arm64.msix"

mkdir -p "${a}/AccelerANTgine-windows-x64-copy/packages"
cp "${a}/AccelerANTgine-windows-x64/packages/AccelerANTgine-0.0.1-Release-x86_64.msi" "${a}/AccelerANTgine-windows-x64-copy/packages/"
check "two artifacts with one file name fail rather than overwrite" bash -c "! bash '${collect}' '${a}' '${work}/release2' >/dev/null 2>&1"
mkdir -p "${work}/none/x"
check "no packages at all fail" bash -c "! bash '${collect}' '${work}/none' '${work}/release3' >/dev/null 2>&1"

if [ "${fails}" -gt 0 ]; then
  printf '%d of the collect checks failed\n' "${fails}"
  exit 1
fi
printf 'collect-release-assets: all checks passed\n'
