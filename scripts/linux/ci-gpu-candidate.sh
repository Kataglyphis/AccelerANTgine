#!/usr/bin/env bash
# Build a GPU package candidate without claiming hardware verification.
set -euo pipefail

variant="${GPU_VARIANT:?GPU_VARIANT must select nvidia or amd}"
arch="$(uname -m)"
case "${variant}:${arch}" in
  nvidia:x86_64|nvidia:aarch64) provider=cuda ;;
  amd:x86_64) provider=migraphx ;;
  *) printf 'Unsupported GPU variant and architecture: %s %s\n' "${variant}" "${arch}" >&2; exit 2 ;;
esac
if [[ "${GPU_PRODUCER_PROOF:-0}" == 1 ]]; then
  case "${GPU_ARCH:?GPU_ARCH is required}:${arch}" in
    x64:x86_64|arm64:aarch64) ;;
    *) echo 'GPU proof architecture does not match the container' >&2; exit 1 ;;
  esac
fi
hub=third_party/ANTfrastructure/linux/scripts/06-packaging
ort=/usr/local/lib/onnxruntime-gpu/lib
export LD_LIBRARY_PATH="${ort}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
proof="$(mktemp -d)"
trap 'rm -rf -- "${proof}"' EXIT
python3 "${hub}/stage-ort-wheel-licenses.py" --require-unstripped --strip "${STRIP:-strip}" \
  --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --destination "${proof}" \
  --library "${ort}/libonnxruntime.so.1" --library "${ort}/libonnxruntime_providers_shared.so" \
  --library "${ort}/libonnxruntime_providers_${provider}.so"
bash scripts/linux/ci-release.sh --ort-variant "${variant}" --no-flatpak --build-release-dir build-gpu
shopt -s nullglob
for extension in deb tar.gz AppImage; do
  packages=(build-gpu/*."${extension}")
  [[ "${#packages[@]}" -eq 1 ]] || { printf 'Expected one %s package, found %s\n' "${extension}" "${#packages[@]}" >&2; exit 1; }
done
if [[ "${GPU_PRODUCER_PROOF:-0}" == 1 ]]; then
  python3 -I scripts/linux/gpu-producer-proof.py capture --directory build-gpu --proof build-gpu/.producer-before.json
fi
bash scripts/linux/verify-gpu-packages.sh build-gpu "${variant}"
if [[ "${GPU_PRODUCER_PROOF:-0}" == 1 ]]; then
  python3 -I scripts/linux/gpu-producer-proof.py seal --directory build-gpu \
    --before build-gpu/.producer-before.json --proof build-gpu/producer-proof.json
fi
