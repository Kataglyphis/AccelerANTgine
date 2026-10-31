#!/usr/bin/env bash
# Verify the finished tar and DEB GPU runtime against the original wheel.
set -euo pipefail

if [[ $# -ne 2 ]]; then echo 'usage: verify-gpu-packages.sh PACKAGE_DIR nvidia|amd' >&2; exit 2; fi
case "$2" in
  nvidia) kind=cuda ;;
  amd) kind=migraphx ;;
  *) echo 'Unsupported GPU variant' >&2; exit 2 ;;
esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hub="${ANTFRASTRUCTURE_DIR:-$repo/third_party/ANTfrastructure}/linux/scripts/06-packaging"
# shellcheck source=/dev/null
source "$hub/ort-runtime-bundle.sh"
package_dir="$(realpath -e "$1")"
shopt -s nullglob
tarballs=("$package_dir"/*.tar.gz)
debs=("$package_dir"/*.deb)
if [[ ${#tarballs[@]} -ne 1 || ${#debs[@]} -ne 1 ]]; then
  echo 'Expected one tarball and one DEB' >&2; exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/tar" "$work/deb"
tar -xzf "${tarballs[0]}" -C "$work/tar"
dpkg-deb -x "${debs[0]}" "$work/deb"

verify_demo() {
  local root="$1" prefix="$2" resolved
  local demo="$prefix/usr/bin/AccelerANTgine_demo"
  [[ -f "$demo" && ! -L "$demo" && -x "$demo" ]] || { echo 'Missing packaged inference demo' >&2; return 1; }
  resolved="$(realpath -e "$demo")"
  case "$resolved" in "$root/"*) ;; *) echo 'Inference demo escapes package' >&2; return 1 ;; esac
  local demo_binary="$prefix/usr/lib/accelerantgine/AccelerANTgine_demo"
  [[ -f "$demo_binary" && ! -L "$demo_binary" && -x "$demo_binary" ]] || { echo 'Missing inference demo binary' >&2; return 1; }
  resolved="$(realpath -e "$demo_binary")"
  case "$resolved" in "$root/"*) ;; *) echo 'Inference demo binary escapes package' >&2; return 1 ;; esac
}

collect_ort_libraries() {
  local root="$1" lib="$2/usr/lib/accelerantgine" file resolved name
  for name in libonnxruntime.so.1 libonnxruntime_providers_shared.so "libonnxruntime_providers_${kind}.so"; do
    [[ -f "$lib/$name" ]] || { echo "Missing GPU ORT library: $name" >&2; return 1; }
  done
  for file in "$lib"/libonnxruntime*.so*; do
    [[ -f "$file" ]] || { echo "Invalid ORT library: $file" >&2; return 1; }
    resolved="$(realpath -e "$file")"
    case "$resolved" in "$root/"*) ;; *) echo 'ORT library escapes package' >&2; return 1 ;; esac
    name="${file##*/}"
    case "$name" in
      libonnxruntime_providers_*) [[ ! -L "$file" ]] || { echo 'ORT provider is a symlink' >&2; return 1; } ;;
      libonnxruntime.so*) [[ "${resolved##*/}" =~ ^libonnxruntime\.so(\.[0-9]+)*$ ]] || { echo 'ORT core aliases another component' >&2; return 1; } ;;
    esac
    libraries+=(--library "$file")
  done
}

verify_ort_notices() {
  local root="$1" prefix="$2" proof="$3" name notice resolved
  for name in LICENSE ThirdPartyNotices.txt; do
    notice="$prefix/usr/share/licenses/onnxruntime/$name"
    [[ -f "$notice" && ! -L "$notice" ]] || { echo "Missing or linked ORT notice: $notice" >&2; return 1; }
    resolved="$(realpath -e "$notice")"
    case "$resolved" in "$root/"*) ;; *) echo 'ORT notice escapes package' >&2; return 1 ;; esac
    cmp "$notice" "$proof/licenses/onnxruntime/$name"
  done
}

verify_tree() {
  local root="$1" prefix="$2" proof
  local -a libraries=()
  root="$(realpath -e "$root")"
  prefix="$(realpath -e "$prefix")"
  case "$prefix/" in "$root/"*) ;; *) echo 'Package prefix escapes extraction root' >&2; return 1 ;; esac
  verify_demo "$root" "$prefix"
  ort_assert_no_bundled_host_runtime "$root" "$kind"
  collect_ort_libraries "$root" "$prefix"
  proof="$(mktemp -d "$work/proof.XXXXXX")"
  python3 "$hub/stage-ort-wheel-licenses.py" --require-unstripped \
    --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --destination "$proof" \
    --strip "${STRIP:-strip}" "${libraries[@]}"
  verify_ort_notices "$root" "$prefix" "$proof"
}

mapfile -d '' -t tops < <(find "$work/tar" -mindepth 1 -maxdepth 1 -print0)
[[ ${#tops[@]} -eq 1 && -d ${tops[0]} ]] || { echo 'Tarball must have one top-level directory' >&2; exit 1; }
if [[ "${tops[0]##*/}" == usr ]]; then tar_prefix="$work/tar"; else tar_prefix="${tops[0]}"; fi
verify_tree "$work/tar" "$tar_prefix"
verify_tree "$work/deb" "$work/deb"
for relative in usr/bin/AccelerANTgine_demo usr/lib/accelerantgine/AccelerANTgine_demo; do
  cmp "$tar_prefix/$relative" "$work/deb/$relative" || { echo "GPU packages disagree on $relative" >&2; exit 1; }
done
echo 'PASS: finished GPU tar and DEB ORT payloads and notices match one wheel'
