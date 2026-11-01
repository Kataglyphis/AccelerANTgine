#!/usr/bin/env bash
# Feeds fixture libraries to the chain-only ORT proof; it does not configure the project or load a real ORT.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
failures=0

cat > "${work}/check.cmake" <<'CMAKE'
include("${MODULE}")
accelerantgine_assert_ort_chain_build("${RUNTIME}" "${MARKER}" "${ROOT}")
CMAKE

prove() {
  cmake "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" "-DRUNTIME=$1" "-DMARKER=$2" "-DROOT=${work}" \
    -P "${work}/check.cmake" >"${work}/output" 2>&1
}
expect() {
  local verdict="$1" what="$2"
  shift 2
  if prove "$@"; then got=accepted; else got=refused; fi
  if [[ "${got}" != "${verdict}" ]]; then
    echo "FAIL: ${what}: ${got}, expected ${verdict}" >&2
    cat "${work}/output" >&2
    failures=$((failures + 1))
  else
    echo "ok: ${what}"
  fi
}

linux_marker='/opt/onnxruntime/onnxruntime/core/'
windows_marker='temp.onnx-src.onnxruntime.core.'
printf 'ELF\0\0junk\0/opt/onnxruntime/onnxruntime/core/session/inference_session.cc\0tail\n' > "${work}/chain.so"
printf 'ELF\0\0junk\0/home/runner/onnxruntime/onnxruntime/core/session/inference_session.cc\0tail\n' > "${work}/pypi.so"
printf 'MZ\0\0D:\\a\\temp.onnx-src.onnxruntime.core.session.cc\0\n' > "${work}/chain.dll"
printf 'MZ\0\0C:\\vendor\\onnxruntime\\core\\session.cc\0\n' > "${work}/vendor.dll"

expect accepted 'a Linux chain build' "${work}/chain.so" "${linux_marker}"
expect refused 'a Linux ORT built anywhere else' "${work}/pypi.so" "${linux_marker}"
expect accepted 'a Windows chain build' "${work}/chain.dll" "${windows_marker}"
expect refused 'a vendor Windows ORT' "${work}/vendor.dll" "${windows_marker}"
expect refused 'a missing runtime' "${work}/absent.so" "${linux_marker}"
grep -q 'is missing, so' "${work}/output" || { echo 'FAIL: a missing runtime must be named as missing' >&2; failures=$((failures + 1)); }

[[ "${failures}" -eq 0 ]] || { echo "${failures} chain-proof case(s) failed" >&2; exit 1; }
echo 'chain-only ORT proof: all cases passed'
