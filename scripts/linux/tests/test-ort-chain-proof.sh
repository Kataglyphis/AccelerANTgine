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

# GenAI: the header search and the same proof for the library text_generation.cpp loads by name.
cat > "${work}/genai.cmake" <<'CMAKE'
include("${MODULE}")
accelerantgine_find_chain_genai("${ROOT}" "${SYSTEM}" include_dir)
message(STATUS "GENAI-INCLUDE=${include_dir}")
CMAKE
genai() {
  cmake "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" "-DROOT=$1" "-DSYSTEM=$2" -P "${work}/genai.cmake" \
    >"${work}/output" 2>&1
}
expect_genai() {
  local verdict="$1" what="$2"
  shift 2
  if genai "$@"; then got=accepted; else got=refused; fi
  if [[ "${got}" != "${verdict}" ]]; then
    echo "FAIL: ${what}: ${got}, expected ${verdict}" >&2
    cat "${work}/output" >&2
    failures=$((failures + 1))
  else
    echo "ok: ${what}"
  fi
}
genai_root() {  # <dir> <library path under it> <bytes>: a GenAI prefix with its header and one library
  mkdir -p "$1/include" "$(dirname "$1/$2")"
  : > "$1/include/ort_genai_c.h"
  printf '%b' "$3" > "$1/$2"
}
genai_root "${work}/genai-chain" lib/libonnxruntime-genai.so 'ELF\0/opt/onnxruntime-genai/build/Linux/Release/_deps/dlib-src/dlib/matrix.h\0'
genai_root "${work}/genai-pip" lib/libonnxruntime-genai.so 'ELF\0/home/runner/work/onnxruntime-genai/src/generators.cpp\0'
genai_root "${work}/genai-win" bin/onnxruntime-genai.dll 'MZ\0C:\\temp\\onnx-genai-src\\src\\generators.cpp\0'
genai_root "${work}/genai-vendor" lib/onnxruntime-genai.dll 'MZ\0C:\\vendor\\genai\\generators.cpp\0'
mkdir -p "${work}/genai-headless/include" && : > "${work}/genai-headless/include/ort_genai_c.h"

expect_genai accepted 'a Linux chain GenAI' "${work}/genai-chain" Linux
grep -q "GENAI-INCLUDE=${work}/genai-chain/include" "${work}/output" \
  || { echo 'FAIL: a chain GenAI must hand back its header dir' >&2; failures=$((failures + 1)); }
expect_genai refused 'a Linux GenAI built anywhere else' "${work}/genai-pip" Linux
grep -q 'ONNX Runtime GenAI:' "${work}/output" \
  || { echo 'FAIL: a foreign GenAI must be named as GenAI' >&2; failures=$((failures + 1)); }
expect_genai accepted 'a Windows chain GenAI in bin' "${work}/genai-win" Windows
expect_genai refused 'a vendor Windows GenAI' "${work}/genai-vendor" Windows
expect_genai refused 'a GenAI header without its library' "${work}/genai-headless" Linux
expect_genai refused 'no GenAI header at all' "${work}/absent" Linux

[[ "${failures}" -eq 0 ]] || { echo "${failures} chain-proof case(s) failed" >&2; exit 1; }
echo 'chain-only ORT proof: all cases passed'
