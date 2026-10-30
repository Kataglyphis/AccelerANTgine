#!/usr/bin/env bash
# Check both finished package formats reject independent GPU payload mutations.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
hub="$work/hub/linux/scripts/06-packaging"
mkdir -p "$hub" "$work/bin" "$work/packages" "$work/tree/usr/bin" "$work/tree/usr/lib/accelerantgine" "$work/tree/usr/share/licenses/onnxruntime"
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
check() { bash "$repo/scripts/linux/verify-gpu-packages.sh" "$work/packages" "$1" >/dev/null 2>&1; }
for vendor in nvidia amd; do
  case "$vendor" in nvidia) kind=cuda; host=libcuda.so.1 ;; amd) kind=migraphx; host=libamdhip64.so.7 ;; esac
  provider="libonnxruntime_providers_${kind}.so"
  printf '%s\n' "$provider" > "$lib/$provider"
  pack_tar; pack_deb
  check "$vendor" || { echo "Valid $vendor candidate failed" >&2; exit 1; }
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
  rm "$lib/$host" "$lib/$provider"
done
if check unsupported; then echo 'Unknown vendor passed' >&2; exit 1; fi
echo 'GPU tar and DEB package verification mutation tests passed'
