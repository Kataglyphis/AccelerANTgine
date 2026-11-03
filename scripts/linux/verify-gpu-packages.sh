#!/usr/bin/env bash
# Verify finished GPU packages against the original wheel and locked model.
set -euo pipefail

if [[ $# -ne 2 ]]; then echo 'usage: verify-gpu-packages.sh PACKAGE_DIR nvidia|amd' >&2; exit 2; fi
case "$2" in
  nvidia) kind=cuda ;;
  amd) kind=migraphx ;;
  *) echo 'Unsupported GPU variant' >&2; exit 2 ;;
esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hub_root="${ANTFRASTRUCTURE_DIR:-$repo/third_party/ANTfrastructure}"
hub="$hub_root/linux/scripts/06-packaging"
model_verifier="$hub_root/shared/python/verify_locked_files.py"
model_fetcher="$hub_root/linux/scripts/lib/fetch-data-lock.py"
[[ -f "$model_verifier" && -f "$model_fetcher" ]] || { echo 'Pinned ANTfrastructure lacks locked-model verification APIs' >&2; exit 1; }
appimage_verifier="$hub/verify-ort-appimage-payload.sh"
[[ -f "$appimage_verifier" ]] || { echo 'Pinned ANTfrastructure lacks AppImage GPU payload verification' >&2; exit 1; }
# shellcheck source=/dev/null
source "$hub/ort-runtime-bundle.sh"
# shellcheck source=/dev/null
source "$hub/ort-package-proof.sh"
package_dir="$(realpath -e "$1")"
shopt -s nullglob
tarballs=("$package_dir"/*.tar.gz)
debs=("$package_dir"/*.deb)
images=("$package_dir"/*.AppImage)
if [[ ${#tarballs[@]} -ne 1 || ${#debs[@]} -ne 1 || ${#images[@]} -ne 1 ]]; then
  echo 'Expected one tarball, one DEB and one AppImage' >&2; exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/tar" "$work/deb"
tar -xzf "${tarballs[0]}" -C "$work/tar"
dpkg-deb -x "${debs[0]}" "$work/deb"

# Usage: require_inside ROOT PATH MESSAGE; a directory PATH carries a trailing slash, so ROOT itself matches.
require_inside() {
  case "$2" in "$1/"*) ;; *) echo "$3" >&2; return 1 ;; esac
}

# Usage: verify_packaged_program ROOT PATH MISSING_MESSAGE ESCAPE_MESSAGE; a parent directory link can still leave ROOT.
verify_packaged_program() {
  local resolved
  [[ -f "$2" && ! -L "$2" && -x "$2" ]] || { echo "$3" >&2; return 1; }
  resolved="$(realpath -e "$2")"
  require_inside "$1" "$resolved" "$4"
}

verify_demo() {
  verify_packaged_program "$1" "$2/usr/bin/AccelerANTgine_demo" 'Missing packaged inference demo' 'Inference demo escapes package'
  verify_packaged_program "$1" "$2/usr/lib/accelerantgine/AccelerANTgine_demo" 'Missing inference demo binary' 'Inference demo binary escapes package'
}

verify_tree() {
  local root="$1" prefix="$2" proof
  local -a libraries=()
  root="$(realpath -e "$root")"
  prefix="$(realpath -e "$prefix")"
  require_inside "$root" "$prefix/" 'Package prefix escapes extraction root'
  verify_demo "$root" "$prefix"
  ort_assert_no_bundled_host_runtime "$root" "$kind"
  ort_package_collect_libraries --reject-invalid "$root" "$prefix/usr/lib/accelerantgine" libraries \
    libonnxruntime.so.1 libonnxruntime_providers_shared.so "libonnxruntime_providers_${kind}.so"
  proof="$(mktemp -d "$work/proof.XXXXXX")"
  python3 "$hub/stage-ort-wheel-licenses.py" --require-unstripped \
    --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --destination "$proof" \
    --strip "${STRIP:-strip}" "${libraries[@]}"
  ort_package_verify_notices "$root" "$prefix/usr/share/licenses/onnxruntime" "$proof/licenses/onnxruntime"
}

mapfile -d '' -t tops < <(find "$work/tar" -mindepth 1 -maxdepth 1 -print0)
[[ ${#tops[@]} -eq 1 && -d ${tops[0]} ]] || { echo 'Tarball must have one top-level directory' >&2; exit 1; }
if [[ "${tops[0]##*/}" == usr ]]; then tar_prefix="$work/tar"; else tar_prefix="${tops[0]}"; fi
verify_tree "$work/tar" "$tar_prefix"
verify_tree "$work/deb" "$work/deb"
verify_model() {
  local root="$1" prefix="$2"
  python3 -I "$model_verifier" --root "$root" --directory "$prefix/usr/share/accelerantgine/models" \
    --fetcher "$model_fetcher" --lock "$repo/models/models.lock" \
    --file deim_dfine_n_coco.onnx --file deim_dfine_n_coco.LICENSE --file deim_dfine_n_coco.NOTICE
}
verify_model "$work/tar" "$tar_prefix"
verify_model "$work/deb" "$work/deb"
mkdir "$work/appimage"
cp -- "${images[0]}" "$work/candidate.AppImage"
chmod u+x "$work/candidate.AppImage"
env -u LD_PRELOAD -u LD_AUDIT bash "$appimage_verifier" "$work/candidate.AppImage" "$(uname -m)" usr/lib/accelerantgine usr/share/licenses/onnxruntime "$2"
(cd "$work/appimage" && env -u LD_PRELOAD -u LD_AUDIT "$work/candidate.AppImage" --appimage-extract >/dev/null)
verify_model "$work/appimage/squashfs-root" "$work/appimage/squashfs-root"
verify_demo "$work/appimage/squashfs-root" "$work/appimage/squashfs-root"
for relative in usr/bin/AccelerANTgine_demo usr/lib/accelerantgine/AccelerANTgine_demo; do
  cmp "$tar_prefix/$relative" "$work/deb/$relative" || { echo "GPU packages disagree on $relative" >&2; exit 1; }
  cmp "$tar_prefix/$relative" "$work/appimage/squashfs-root/$relative" || { echo "AppImage disagrees on $relative" >&2; exit 1; }
done
echo 'PASS: finished GPU package ORT payloads and locked models match their sources'
