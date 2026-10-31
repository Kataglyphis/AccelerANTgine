#!/usr/bin/env bash
# Checks PIE, BIND_NOW, stack-protector and fortify imports in the .deb and .tar.gz; not the demo's fortify, CET/IBT, RELRO segments, static linking, bundled ELFs, AppImage or Flatpak.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo 'usage: verify-package-hardening.sh PACKAGE_DIR' >&2
  exit 2
fi
package_dir="$(realpath -e "$1")"
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

undefined_imports() {
  readelf --dyn-syms -W "$1" | awk '$7 == "UND" && $8 != "" { sub(/@.*/, "", $8); print $8 }'
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

check_elf() {
  local label="$1" file="$2" kind="$3" fortify="$4" header program dynamic imports verdict="" before="$failures"
  header="$(readelf -hW "$file")" || { fail "$label: readelf -h failed"; return 0; }
  program="$(readelf -lW "$file")" || { fail "$label: readelf -l failed"; return 0; }
  dynamic="$(readelf -dW "$file")" || { fail "$label: readelf -d failed"; return 0; }
  imports="$(undefined_imports "$file")" || { fail "$label: readelf --dyn-syms failed"; return 0; }
  if [[ "$kind" == executable ]]; then
    if grep -Eq '^ *Type: +DYN ' <<< "$header" && grep -Eq '^ *INTERP ' <<< "$program"; then
      verdict+=" PIE"
    else
      fail "$label: not PIE (needs ELF type DYN and an INTERP segment)"
    fi
  fi
  if grep -Eq '\(FLAGS\).*\bBIND_NOW\b|\(FLAGS_1\).*\bNOW\b' <<< "$dynamic"; then
    verdict+=" BIND_NOW"
  else
    fail "$label: no BIND_NOW (DT_FLAGS BIND_NOW or DT_FLAGS_1 NOW)"
  fi
  if grep -qx '__stack_chk_fail' <<< "$imports"; then
    verdict+=" __stack_chk_fail"
  else
    fail "$label: no __stack_chk_fail import (stack protector)"
  fi
  local fortified
  fortified="$(grep -E -m 1 '^__[A-Za-z0-9_]+_chk$' <<< "$imports" || true)"
  if [[ -n "$fortified" ]]; then
    verdict+=" $fortified"
  elif [[ "$fortify" == fortify ]]; then
    fail "$label: no __*_chk import (_FORTIFY_SOURCE)"
  fi
  if [[ $failures -eq $before ]]; then
    printf 'hardening ok: %s:%s\n' "$label" "$verdict"
  fi
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
