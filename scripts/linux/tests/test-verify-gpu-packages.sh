#!/usr/bin/env bash
# Check finished packages reject independent GPU payload and model mutations.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_hub="${ANTFRASTRUCTURE_DIR:-$repo/third_party/ANTfrastructure}"
real_python="$(command -v python3)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
hub="$work/hub/linux/scripts/06-packaging"
mkdir -p "$hub" "$work/hub/shared/python" "$work/hub/linux/scripts/lib" "$work/hub/linux/scripts/01-core" "$work/source/scripts/linux" "$work/source/models" "$work/bin" "$work/packages" "$work/tree/usr/bin" "$work/tree/usr/lib/accelerantgine" "$work/tree/usr/share/licenses/onnxruntime" "$work/tree/usr/share/accelerantgine/models" "$work/appimage-tree"
cp "$source_hub/shared/python/verify_locked_files.py" "$work/hub/shared/python/verify_locked_files.py"
cp "$source_hub/linux/scripts/lib/fetch-data-lock.py" "$work/hub/linux/scripts/lib/fetch-data-lock.py"
cp "$source_hub/linux/scripts/01-core/platform.sh" "$work/hub/linux/scripts/01-core/platform.sh"
cp "$source_hub/linux/scripts/06-packaging/verify-ort-appimage-payload.sh" "$source_hub/linux/scripts/06-packaging/appimage-verification.sh" "$hub/"
cp "$repo/scripts/linux/verify-gpu-packages.sh" "$work/source/scripts/linux/"
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
cat > "$hub/ort-runtime-bundle.sh" <<'STUB'
ort_assert_no_bundled_host_runtime() {
  case "$2" in cuda) pattern=libcuda.so.1 ;; migraphx) pattern=libamdhip64.so.7 ;; *) return 1 ;; esac
  ! find "$1" -name "$pattern" -print | grep -q .
}
STUB
touch "$hub/stage-ort-wheel-licenses.py"
cat > "$work/bin/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -I ]]; then exec "$REAL_PYTHON" "$@"; fi
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
chmod +x "$work/bin/python3" "$work/bin/dpkg-deb"
export PATH="$work/bin:$PATH" ANTFRASTRUCTURE_DIR="$work/hub"
lib="$work/tree/usr/lib/accelerantgine"
notice="$work/tree/usr/share/licenses/onnxruntime"
printf '#!/bin/sh\nexit 0\n' > "$lib/AccelerANTgine_demo"
chmod +x "$lib/AccelerANTgine_demo"
for name in libonnxruntime.so.1 libonnxruntime_providers_shared.so; do printf '%s\n' "$name" > "$lib/$name"; done
printf 'license\n' > "$notice/LICENSE"
printf 'notices\n' > "$notice/ThirdPartyNotices.txt"
pack_tar() { tar -czf "$work/packages/candidate.tar.gz" -C "$work/tree" usr; }
pack_deb() { tar -czf "$work/packages/candidate.deb" -C "$work/tree" usr; }
check() { bash "$work/source/scripts/linux/verify-gpu-packages.sh" "$work/packages" "$1" >/dev/null 2>&1; }
vendors=(nvidia)
case "$(uname -m)" in x86_64|amd64) vendors+=(amd) ;; aarch64|arm64) ;; *) echo 'Unsupported fixture architecture' >&2; exit 1 ;; esac
for vendor in "${vendors[@]}"; do
  case "$vendor" in nvidia) kind=cuda; host=libcuda.so.1 ;; amd) kind=migraphx; host=libamdhip64.so.7 ;; esac
  provider="libonnxruntime_providers_${kind}.so"
  printf '%s\n' "$provider" > "$lib/$provider"
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
  printf '%s\n' "$provider" > "$app_lib/$provider"
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
  printf '%s\n' "$provider" > "$lib/$provider"
  pack_tar
  printf changed > "$lib/$provider"
  pack_deb
  if check "$vendor"; then echo 'Changed DEB provider passed' >&2; exit 1; fi
  printf '%s\n' "$provider" > "$lib/$provider"
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
  rm "$lib/$host" "$lib/$provider" "$app_lib/$provider"
done
if check unsupported; then echo 'Unknown vendor passed' >&2; exit 1; fi
echo 'GPU package verification mutation tests passed for all formats'
