#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/workspace"
cat > "${work}/bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' "${TEST_ARCH:?}"
STUB
cat > "${work}/bin/python3" <<'STUB'
#!/bin/bash
args=" $* "
for required in ' --require-unstripped ' ' --strip strip ' ' --wheel-dir ' ' --destination '; do
  case "$args" in *"$required"*) ;; *) exit 1 ;; esac
done
case "$args" in *"libonnxruntime_providers_${TEST_PROVIDER:?}.so"*) ;; *) exit 1 ;; esac
case "${LD_LIBRARY_PATH:-}" in /usr/local/lib/onnxruntime-gpu/lib*) ;; *) exit 1 ;; esac
STUB
cat > "${work}/bin/bash" <<'STUB'
#!/bin/bash
if [[ "$*" == "scripts/linux/verify-gpu-packages.sh build-gpu ${GPU_VARIANT}" ]]; then
  exit 0
fi
case "$*" in
  "scripts/linux/ci-release.sh --ort-variant ${GPU_VARIANT} --no-flatpak --build-release-dir build-gpu")
    mkdir -p build-gpu
    for format in deb tar.gz AppImage; do
      [[ "${OMIT_FORMAT:-}" == "$format" ]] || touch "build-gpu/example.${format}"
    done ;;
  "scripts/linux/verify-gpu-packages.sh build-gpu ${GPU_VARIANT}") ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${work}/bin/"*
export PATH="${work}/bin:${PATH}"
cd "${work}/workspace"
check() { GPU_VARIANT="$1" TEST_ARCH="$2" TEST_PROVIDER="$3" /usr/bin/bash "${repo}/scripts/linux/ci-gpu-candidate.sh" >/dev/null 2>&1; }
check nvidia x86_64 cuda || { echo 'NVIDIA x64 candidate was rejected' >&2; exit 1; }
check nvidia aarch64 cuda || { echo 'NVIDIA arm64 candidate was rejected' >&2; exit 1; }
check amd x86_64 migraphx || { echo 'AMD x64 candidate was rejected' >&2; exit 1; }
if check amd aarch64 migraphx; then echo 'AMD arm64 candidate was accepted' >&2; exit 1; fi
if check cpu x86_64 cuda; then echo 'CPU candidate was accepted' >&2; exit 1; fi
rm -rf build-gpu
if OMIT_FORMAT=AppImage check nvidia x86_64 cuda; then echo 'missing AppImage was accepted' >&2; exit 1; fi
printf 'GPU candidate routing, wheel preflight and package checks passed\n'
