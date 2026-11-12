#!/usr/bin/env bash
# Check finished packages reject independent GPU payload and model mutations.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_hub="${ANTFRASTRUCTURE_DIR:-$repo/third_party/ANTfrastructure}"
real_python="$(command -v python3)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
hub="$work/hub/linux/scripts/06-packaging"
mkdir -p "$hub" "$work/hub/shared/python" "$work/hub/linux/scripts/lib" "$work/hub/linux/scripts/01-core" "$work/source/scripts/linux" "$work/source/scripts/packaging" "$work/source/models" "$work/bin" "$work/packages" "$work/tree/usr/bin" "$work/tree/usr/lib/accelerantgine" "$work/tree/usr/share/licenses/onnxruntime" "$work/tree/usr/share/accelerantgine/models" "$work/appimage-tree"
cp "$source_hub/shared/python/verify_locked_files.py" "$work/hub/shared/python/verify_locked_files.py"
cp "$source_hub/linux/scripts/lib/fetch-data-lock.py" "$work/hub/linux/scripts/lib/fetch-data-lock.py"
cp "$source_hub/linux/scripts/01-core/platform.sh" "$work/hub/linux/scripts/01-core/platform.sh"
cp "$source_hub/linux/scripts/06-packaging/verify-ort-appimage-payload.sh" "$source_hub/linux/scripts/06-packaging/appimage-verification.sh" "$source_hub/linux/scripts/06-packaging/ort-package-proof.sh" "$source_hub/linux/scripts/06-packaging/ort-runtime-bundle.sh" "$hub/"
cp "$repo/scripts/linux/verify-gpu-packages.sh" "$work/source/scripts/linux/"
cp "$repo/scripts/packaging/stage_ort_texts.py" "$work/source/scripts/packaging/"
models="$work/tree/usr/share/accelerantgine/models"
for name in deim_dfine_n_coco.onnx deim_dfine_n_coco.LICENSE deim_dfine_n_coco.NOTICE; do
  printf 'fixture %s\n' "$name" > "$models/$name"
  printf '%s  %s  https://example.invalid/%s\n' "$(sha256sum "$models/$name" | cut -d ' ' -f1)" "$name" "$name" >> "$work/source/models/models.lock"
done
export REAL_PYTHON="$real_python" FIXTURE_APPIMAGE_TREE="$work/appimage-tree"
cat > "$work/packages/candidate.AppImage" <<'APPIMAGE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" = 1 && "$1" = --appimage-extract ]]
mkdir -p squashfs-root
cp -a "$FIXTURE_APPIMAGE_TREE/." squashfs-root/
APPIMAGE
chmod +x "$work/packages/candidate.AppImage"
printf '#!/bin/sh\nexit 0\n' > "$work/tree/usr/bin/AccelerANTgine_demo"
chmod +x "$work/tree/usr/bin/AccelerANTgine_demo"
touch "$hub/stage-ort-wheel-licenses.py"
cat > "$work/bin/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -I || "$1" == */stage_ort_texts.py ]]; then exec "$REAL_PYTHON" "$@"; fi
shift
destination= strip_seen=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination) destination=$2; shift 2 ;;
    --library) [[ "$(cat "$2")" == "${2##*/}" ]] || exit 1; shift 2 ;;
    --strip) [[ -n "$2" ]] || exit 1; strip_seen=true; shift 2 ;;
    --wheel-dir) shift 2 ;;
    --require-unstripped) shift ;;
    *) exit 1 ;;
  esac
done
[[ "$strip_seen" == true ]] || exit 1
mkdir -p "$destination/licenses/onnxruntime"
printf 'license\n' > "$destination/licenses/onnxruntime/LICENSE"
printf 'notices\n' > "$destination/licenses/onnxruntime/ThirdPartyNotices.txt"
STUB
cat > "$work/bin/dpkg-deb" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -x ]] || exit 1
tar -xzf "$2" -C "$3"
STUB
# AMD packages exist for x64 alone, so the amd legs name that machine on every host.
cat > "$work/bin/uname" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${TEST_UNAME:-}" ]]; then printf '%s\n' "$TEST_UNAME"; else exec /usr/bin/uname "$@"; fi
STUB
chmod +x "$work/bin/python3" "$work/bin/dpkg-deb" "$work/bin/uname"
export PATH="$work/bin:$PATH" ANTFRASTRUCTURE_DIR="$work/hub"
lib="$work/tree/usr/lib/accelerantgine"
notice="$work/tree/usr/share/licenses/onnxruntime"
printf '#!/bin/sh\nexit 0\n' > "$lib/AccelerANTgine_demo"
chmod +x "$lib/AccelerANTgine_demo"
printf 'license\n' > "$notice/LICENSE"
printf 'notices\n' > "$notice/ThirdPartyNotices.txt"
# The image side of an AMD package: the CPU build with its texts, and the plugin's root as the rocm image lays it out.
image_ep="$work/image/onnxruntime-ep-amdgpu"
chain="$work/image/onnxruntime-cpu"
mkdir -p "$image_ep/lib" "$image_ep/licenses/onnxruntime-ep-amdgpu/LICENSES" "$image_ep/licenses/fmt" "$chain/lib" "$chain/licenses"
printf 'plugin module\n' > "$image_ep/lib/libmigraphx-ep.so"
printf 'plugin license\n' > "$image_ep/licenses/onnxruntime-ep-amdgpu/LICENSE"
printf 'apache\n' > "$image_ep/licenses/onnxruntime-ep-amdgpu/LICENSES/Apache-2.0.txt"
printf 'fmt license\n' > "$image_ep/licenses/fmt/LICENSE"
printf 'onnxruntime-ep-amdgpu fixture\n' > "$image_ep/provenance.txt"
printf 'libonnxruntime.so.1\n' > "$chain/lib/libonnxruntime.so.1.31.1"
printf 'license\n' > "$chain/licenses/LICENSE"
printf 'notices\n' > "$chain/licenses/ThirdPartyNotices.txt"
export ORT_AMDGPU_EP_ROOT="$image_ep" ORT_LIB_LOCATION="$chain/lib"
plugin_texts="$work/tree/usr/share/licenses/AccelerANTgine/third-party/onnxruntime-ep-amdgpu"
app_plugin_texts="$work/appimage-tree/usr/share/licenses/AccelerANTgine/third-party/onnxruntime-ep-amdgpu"
pack_tar() { tar -czf "$work/packages/candidate.tar.gz" -C "$work/tree" usr; }
pack_deb() { tar -czf "$work/packages/candidate.deb" -C "$work/tree" usr; }
check() { TEST_UNAME="$fixture_uname" bash "$work/source/scripts/linux/verify-gpu-packages.sh" "$work/packages" "$1" >/dev/null 2>&1; }
# Usage: restore_provider LIB_DIR; the GPU module as its source has it.
restore_provider() {
  if [[ "$vendor" == amd ]]; then cp "$image_ep/lib/$provider" "$1/$provider"; else printf '%s\n' "$provider" > "$1/$provider"; fi
}
# Usage: refused MESSAGE; the tarball and the DEB are repacked from the tree first.
refused() { pack_tar; pack_deb; if check "$vendor"; then echo "$1" >&2; exit 1; fi; }
case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ;; *) echo 'Unsupported fixture architecture' >&2; exit 1 ;; esac
for vendor in nvidia amd; do
  fixture_uname=
  printf 'libonnxruntime.so.1\n' > "$lib/libonnxruntime.so.1"
  if [[ "$vendor" == nvidia ]]; then
    host=libcuda.so.1 provider=libonnxruntime_providers_cuda.so
    printf 'libonnxruntime_providers_shared.so\n' > "$lib/libonnxruntime_providers_shared.so"
  else
    host=libamdhip64.so.7 provider=libmigraphx-ep.so fixture_uname=x86_64
    mkdir -p "$plugin_texts"
    cp -R "$image_ep/licenses" "$image_ep/provenance.txt" "$plugin_texts/"
  fi
  restore_provider "$lib"
  rm -rf "$work/appimage-tree"
  mkdir "$work/appimage-tree"
  cp -a "$work/tree/." "$work/appimage-tree/"
  pack_tar; pack_deb
  check "$vendor" || { bash "$work/source/scripts/linux/verify-gpu-packages.sh" "$work/packages" "$vendor" || true; echo "Valid $vendor candidate failed" >&2; exit 1; }
  mv "$hub/verify-ort-appimage-payload.sh" "$work/missing-appimage-verifier"
  if check "$vendor"; then echo 'Missing shared AppImage verifier passed' >&2; exit 1; fi
  mv "$work/missing-appimage-verifier" "$hub/verify-ort-appimage-payload.sh"
  for format in tar deb appimage; do
    for name in deim_dfine_n_coco.onnx deim_dfine_n_coco.LICENSE deim_dfine_n_coco.NOTICE; do
      if [[ "$format" == appimage ]]; then target="$work/appimage-tree/usr/share/accelerantgine/models/$name"; else target="$models/$name"; fi
      mv "$target" "$target.backup"
      case "$format" in tar) pack_tar ;; deb) pack_deb ;; esac
      if check "$vendor"; then echo "$format missing $name passed" >&2; exit 1; fi
      printf 'tampered\n' > "$target"
      case "$format" in tar) pack_tar ;; deb) pack_deb ;; esac
      if check "$vendor"; then echo "$format with changed $name passed" >&2; exit 1; fi
      mv -f "$target.backup" "$target"
      case "$format" in tar) pack_tar ;; deb) pack_deb ;; esac
    done
  done
  app_lib="$work/appimage-tree/usr/lib/accelerantgine"
  app_notice="$work/appimage-tree/usr/share/licenses/onnxruntime"
  mv "$app_lib/$provider" "$work/missing-provider"
  if check "$vendor"; then echo 'Missing AppImage provider passed' >&2; exit 1; fi
  mv "$work/missing-provider" "$app_lib/$provider"
  printf changed > "$app_lib/$provider"
  if check "$vendor"; then echo 'Changed AppImage provider passed' >&2; exit 1; fi
  restore_provider "$app_lib"
  printf changed > "$app_notice/LICENSE"
  if check "$vendor"; then echo 'Changed AppImage notice passed' >&2; exit 1; fi
  printf 'license\n' > "$app_notice/LICENSE"
  printf '#!/bin/sh\nexit 1\n' > "$app_lib/AccelerANTgine_demo"
  if check "$vendor"; then echo 'Changed AppImage inference demo passed' >&2; exit 1; fi
  printf '#!/bin/sh\nexit 0\n' > "$app_lib/AccelerANTgine_demo"
  touch "$app_lib/$host"
  if check "$vendor"; then echo 'AppImage with bundled host GPU runtime passed' >&2; exit 1; fi
  rm "$app_lib/$host"
  rm "$work/tree/usr/bin/AccelerANTgine_demo"
  pack_tar
  if check "$vendor"; then echo 'Tar without inference demo passed' >&2; exit 1; fi
  printf '#!/bin/sh\nexit 0\n' > "$work/tree/usr/bin/AccelerANTgine_demo"
  chmod +x "$work/tree/usr/bin/AccelerANTgine_demo"
  pack_tar
  printf '#!/bin/sh\nexit 1\n' > "$lib/AccelerANTgine_demo"
  pack_deb
  if check "$vendor"; then echo 'DEB with altered inference demo passed' >&2; exit 1; fi
  printf '#!/bin/sh\nexit 0\n' > "$lib/AccelerANTgine_demo"
  pack_deb
  printf changed > "$lib/$provider"
  pack_tar
  if check "$vendor"; then echo 'Changed tar provider passed' >&2; exit 1; fi
  restore_provider "$lib"
  pack_tar
  printf changed > "$lib/$provider"
  pack_deb
  if check "$vendor"; then echo 'Changed DEB provider passed' >&2; exit 1; fi
  restore_provider "$lib"
  pack_deb
  printf changed > "$notice/LICENSE"
  pack_deb
  if check "$vendor"; then echo 'Changed DEB notice passed' >&2; exit 1; fi
  printf 'license\n' > "$notice/LICENSE"
  mkdir -p "$work/tree/usr/misplaced/accelerantgine"
  mv "$lib/$provider" "$work/tree/usr/misplaced/accelerantgine/$provider"
  pack_tar; pack_deb
  if check "$vendor"; then echo 'Misplaced GPU provider passed' >&2; exit 1; fi
  mv "$work/tree/usr/misplaced/accelerantgine/$provider" "$lib/$provider"
  rmdir "$work/tree/usr/misplaced/accelerantgine" "$work/tree/usr/misplaced"
  printf changed > "$lib/libonnxruntime_providers_unexpected.so"
  pack_tar; pack_deb
  if check "$vendor"; then echo 'Unexpected mutated provider passed' >&2; exit 1; fi
  rm "$lib/libonnxruntime_providers_unexpected.so"
  touch "$lib/$host"
  pack_tar; pack_deb
  if check "$vendor"; then echo 'Bundled host GPU runtime passed' >&2; exit 1; fi
  rm "$lib/$host"
  if [[ "$vendor" == amd ]]; then
    printf 'libonnxruntime_providers_shared.so\n' > "$lib/libonnxruntime_providers_shared.so"
    refused 'An AMD package with an in-tree provider file passed'
    rm "$lib/libonnxruntime_providers_shared.so"
    printf 'another build\n' > "$chain/lib/libonnxruntime.so.1.31.1"
    refused "An AMD package whose core is not the image's CPU build passed"
    printf 'libonnxruntime.so.1\n' > "$chain/lib/libonnxruntime.so.1.31.1"
    printf 'changed\n' > "$plugin_texts/licenses/fmt/LICENSE"
    refused 'A changed plugin licence text passed'
    cp "$image_ep/licenses/fmt/LICENSE" "$plugin_texts/licenses/fmt/LICENSE"
    rm "$plugin_texts/licenses/onnxruntime-ep-amdgpu/LICENSES/Apache-2.0.txt"
    refused 'A missing plugin licence text passed'
    cp "$image_ep/licenses/onnxruntime-ep-amdgpu/LICENSES/Apache-2.0.txt" "$plugin_texts/licenses/onnxruntime-ep-amdgpu/LICENSES/"
    rm "$plugin_texts/provenance.txt"
    refused 'A package without the plugin provenance passed'
    cp "$image_ep/provenance.txt" "$plugin_texts/provenance.txt"
    ln -s provenance.txt "$plugin_texts/linked.txt"
    refused 'A linked plugin text passed'
    rm "$plugin_texts/linked.txt"
    printf 'changed\n' > "$app_plugin_texts/licenses/fmt/LICENSE"
    refused 'A changed AppImage plugin licence text passed'
    cp "$image_ep/licenses/fmt/LICENSE" "$app_plugin_texts/licenses/fmt/LICENSE"
    for side in "$image_ep" "$plugin_texts" "$app_plugin_texts"; do : > "$side/provenance.txt"; done
    refused 'An empty plugin provenance in the image and the package passed'
    for side in "$image_ep" "$plugin_texts" "$app_plugin_texts"; do
      printf 'onnxruntime-ep-amdgpu fixture\n' > "$side/provenance.txt"
      mv "$side/licenses" "$side/licenses.keep"
      mkdir "$side/licenses"
    done
    refused 'An empty plugin licence tree in the image and the package passed'
    for side in "$image_ep" "$plugin_texts" "$app_plugin_texts"; do
      rmdir "$side/licenses"
      mv "$side/licenses.keep" "$side/licenses"
    done
    pack_tar; pack_deb
    check amd || { echo 'The restored AMD candidate failed' >&2; exit 1; }
    fixture_uname=aarch64
    refused 'An AMD candidate on arm64 passed'
    rm -r "$work/tree/usr/share/licenses/AccelerANTgine"
  fi
  rm -f "$lib/$provider" "$lib"/libonnxruntime*
done
fixture_uname=
if check unsupported; then echo 'Unknown vendor passed' >&2; exit 1; fi
echo 'GPU package verification mutation tests passed for all formats'
