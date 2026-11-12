#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
repo=$SUITE_ROOT work=$SUITE_WORK
hub=third_party/ANTfrastructure/linux/scripts/06-packaging
mkdir -p "${work}/bin" "${work}/workspace/${hub}" "${work}/image/lib"
cp "${repo}/${hub}/ort-runtime-bundle.sh" "${work}/workspace/${hub}/"
cat > "${work}/bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' "${TEST_ARCH:?}"
STUB
# The wheel proof is the NVIDIA lane's: AMD's plugin module is no wheel's, and its core is the CPU build.
cat > "${work}/bin/python3" <<'STUB'
#!/bin/bash
[[ "${GPU_VARIANT}" == nvidia ]] || exit 1
args=" $* "
ort=/usr/local/lib/onnxruntime-gpu/lib
for required in ' --require-unstripped ' ' --strip strip ' ' --wheel-dir ' ' --destination ' \
  " --library ${ort}/libonnxruntime.so.1 " " --library ${ort}/libonnxruntime_providers_shared.so " \
  " --library ${ort}/libonnxruntime_providers_cuda.so "; do
  case "$args" in *"$required"*) ;; *) exit 1 ;; esac
done
touch "${TEST_WHEEL_PROOF:?}"
STUB
cat > "${work}/bin/bash" <<'STUB'
#!/bin/bash
if [[ "$*" == "scripts/linux/verify-gpu-packages.sh build-gpu ${GPU_VARIANT}" ]]; then
  exit 0
fi
case "$*" in
  "scripts/linux/ci-release.sh --ort-variant ${GPU_VARIANT} --no-flatpak --build-release-dir build-gpu")
    case "${GPU_VARIANT}:${LD_LIBRARY_PATH:-}" in
      nvidia:/usr/local/lib/onnxruntime-gpu/lib*) [[ -e "${TEST_WHEEL_PROOF:?}" ]] || exit 1 ;;
      amd:/usr/local/lib/onnxruntime-cpu/lib*) ;;
      *) exit 1 ;;
    esac
    mkdir -p build-gpu
    for format in deb tar.gz AppImage; do
      [[ "${OMIT_FORMAT:-}" == "$format" ]] || touch "build-gpu/example.${format}"
    done ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${work}/bin/"*
export PATH="${work}/bin:${PATH}" TEST_WHEEL_PROOF="${work}/wheel-proof"
cd "${work}/workspace"
check() {
  rm -rf build-gpu "${TEST_WHEEL_PROOF}"
  GPU_VARIANT="$1" TEST_ARCH="$2" ORT_AMDGPU_EP_ROOT="${work}/image" /usr/bin/bash "${repo}/scripts/linux/ci-gpu-candidate.sh" >/dev/null 2>&1
}
check nvidia x86_64 || { echo 'NVIDIA x64 candidate was rejected' >&2; exit 1; }
check nvidia aarch64 || { echo 'NVIDIA arm64 candidate was rejected' >&2; exit 1; }
if check amd x86_64; then echo "AMD candidate without the image's plugin module was accepted" >&2; exit 1; fi
[[ ! -e build-gpu ]] || { echo 'The AMD build started without the plugin module' >&2; exit 1; }
touch "${work}/image/lib/libmigraphx-ep.so"
check amd x86_64 || { echo 'AMD x64 candidate was rejected' >&2; exit 1; }
[[ ! -e "${TEST_WHEEL_PROOF}" ]] || { echo 'The AMD candidate ran a wheel proof' >&2; exit 1; }
if check amd aarch64; then echo 'AMD arm64 candidate was accepted' >&2; exit 1; fi
if check cpu x86_64; then echo 'CPU candidate was accepted' >&2; exit 1; fi
if OMIT_FORMAT=AppImage check nvidia x86_64; then echo 'missing AppImage was accepted' >&2; exit 1; fi
printf 'GPU candidate routing, image preflight and package checks passed\n'
