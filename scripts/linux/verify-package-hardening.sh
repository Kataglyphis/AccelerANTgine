#!/usr/bin/env bash
# The .deb and .tar.gz ELFs through the hub's ELF gate (PIE, RELRO, BIND_NOW, SSP, fortify); not CET/IBT or AppImage.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo 'usage: verify-package-hardening.sh PACKAGE_DIR' >&2
  exit 2
fi
package_dir="$(realpath -e "$1")"
# The hub as every other release step finds it: ANTFRASTRUCTURE_DIR, the submodule or a sibling clone.
# shellcheck source=lib/antfrastructure.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/antfrastructure.sh"
gate="$(antfrastructure_path linux/scripts/06-packaging/verify-elf-hardening.sh)" || {
  echo 'hardening FAIL: the hub ELF gate is missing, so no package was graded' >&2
  exit 1
}
library=libAccelerANTgine.so
# The demo calls no libc function _FORTIFY_SOURCE can bound, so it never imports a __*_chk.
targets=("AccelerANTgine executable fortify" "AccelerANTgine_demo executable no-fortify" "$library library fortify")

shopt -s nullglob
packages=("$package_dir"/*.deb "$package_dir"/*.tar.gz)
debs=("$package_dir"/*.deb)
tarballs=("$package_dir"/*.tar.gz)
shopt -u nullglob
[[ ${#debs[@]} -gt 0 ]] || { echo "hardening FAIL: no .deb in $package_dir" >&2; exit 1; }
[[ ${#tarballs[@]} -gt 0 ]] || { echo "hardening FAIL: no .tar.gz in $package_dir" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
failures=0

fail() {
  printf 'hardening FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

# The only ELF of that name: the package's usr/bin entry is a launcher script, so a script never counts.
find_elf() {
  local root="$1" name="$2" candidate
  local -a found=()
  while IFS= read -r -d '' candidate; do
    if readelf -h "$candidate" > /dev/null 2>&1; then
      found+=("$candidate")
    fi
  done < <(find "$root" -type f -name "$name" -print0)
  [[ ${#found[@]} -eq 1 ]] || return 1
  printf '%s\n' "${found[0]}"
}

# The hub's gate grades one ELF (CON294); its lines name the extracted path, which this package label replaces.
check_elf() {
  local label="$1" file="$2" kind="$3" fortify="$4" out rc=0 verdicts
  out="$(bash "${gate}" "${file}:${kind}:${fortify}" 2>&1)" || rc=$?
  out="${out//"${file}"/"${label}"}"
  if [[ $rc -eq 0 ]]; then
    verdicts="$(grep '^hardening ok: ' <<< "${out}" || true)"
    if [[ -n "$verdicts" ]]; then printf '%s\n' "$verdicts"; return 0; fi
  else
    verdicts="$(grep '^hardening FAIL: ' <<< "${out}" || true)"
    if [[ -n "$verdicts" ]]; then
      printf '%s\n' "$verdicts" >&2
      failures=$((failures + $(grep -c '' <<< "$verdicts")))
      return 0
    fi
  fi
  # A gate that could not run (a missing file, a usage error) names no check, so its own words say why.
  fail "${label}: the hub ELF gate exited ${rc} without a verdict: ${out}"
}

for package in "${packages[@]}"; do
  root="$work/$(basename "$package")"
  mkdir -p "$root"
  case "$package" in
    *.deb) dpkg-deb -x "$package" "$root" ;;
    *.tar.gz) tar -xzf "$package" -C "$root" ;;
  esac
  for target in "${targets[@]}"; do
    read -r name kind fortify <<< "$target"
    if file="$(find_elf "$root" "$name")"; then
      check_elf "${package##*/}/$name" "$file" "$kind" "$fortify"
    else
      fail "${package##*/}: not exactly one ELF named $name"
    fi
  done
done

if [[ $failures -gt 0 ]]; then
  printf 'hardening: %d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'hardening: the executables and %s passed in %d package(s)\n' "$library" "${#packages[@]}"
