#!/usr/bin/env bash
# Checks matrix, shared API and install-guard wiring; it does not run GPU inference.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if LC_ALL=C grep -q $'\r' "${root}/resources/packaging/AccelerANTgine.desktop"; then
  echo 'The AppImage desktop file must use LF line endings' >&2; exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cat > "${work}/check.cmake" <<'CMAKE'
include("${MODULE}")
accelerantgine_validate_ort_package_variant("${VARIANT}" "${SYSTEM}" "${ARCH}" "${TOP}")
if(CHECK_HUB)
  accelerantgine_require_gpu_packaging_hub("${HUB}" helper)
endif()
CMAKE

check() {
  cmake "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" "-DVARIANT=$1" "-DSYSTEM=$2" \
    "-DARCH=$3" "-DTOP=$4" "-DCHECK_HUB=${5:-OFF}" "-DHUB=${work}/hub" -P "${work}/check.cmake" \
    >"${work}/output" 2>&1
}
for spec in 'cpu Linux x86_64 ON' 'cpu Linux aarch64 ON' 'cpu Windows ARM64 ON' \
    'nvidia Linux x86_64 ON' 'nvidia Linux aarch64 ON' 'amd Linux x86_64 ON' \
    'nvidia Windows AMD64 ON' 'amd Windows AMD64 ON'; do
  read -r -a args <<< "${spec}"
  check "${args[@]}" || { cat "${work}/output" >&2; exit 1; }
done
for spec in 'amd Linux aarch64 ON' 'nvidia Linux riscv64 ON' 'nvidia Windows ARM64 ON' 'amd Windows ARM64 ON' \
    'amd Linux x86_64 OFF' 'unknown Linux x86_64 ON'; do
  read -r -a args <<< "${spec}"
  if check "${args[@]}"; then echo "unexpectedly accepted ${spec}" >&2; exit 1; fi
done
mkdir -p "${work}/ort/bin" "${work}/ort/lib"
cat > "${work}/windows-path.cmake" <<'CMAKE'
include("${MODULE}")
accelerantgine_find_windows_ort_file("${ROOT}" "onnxruntime_providers_cuda.dll" found)
if(NOT found STREQUAL EXPECTED)
  message(FATAL_ERROR "wrong provider path: '${found}', expected '${EXPECTED}'")
endif()
CMAKE
windows_path() {
  cmake "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" "-DROOT=${work}/ort" "-DEXPECTED=$1" \
    -P "${work}/windows-path.cmake" >"${work}/output" 2>&1 || { cat "${work}/output" >&2; exit 1; }
}
windows_path ''
touch "${work}/ort/lib/onnxruntime_providers_cuda.dll"
windows_path "${work}/ort/lib/onnxruntime_providers_cuda.dll"
touch "${work}/ort/bin/onnxruntime_providers_cuda.dll"
windows_path "${work}/ort/bin/onnxruntime_providers_cuda.dll"
if check amd Linux x86_64 ON ON; then echo 'missing shared helper unexpectedly accepted' >&2; exit 1; fi
grep -Fq "GPU packaging needs ANTfrastructure's ORT staging" "${work}/output"
mkdir -p "${work}/hub/linux/scripts/06-packaging" "${work}/hub/cmake"
touch "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh"
touch "${work}/hub/linux/scripts/06-packaging/verify-ort-appimage-payload.sh"
printf '%s\n' '--require-unstripped' > "${work}/hub/linux/scripts/06-packaging/stage-ort-wheel-licenses.py"
printf 'EXTERNAL_LIBRARY_PATH\n' > "${work}/hub/cmake/CPackCommon.cmake"
if check amd Linux x86_64 ON ON; then echo 'missing host-runtime checks unexpectedly accepted' >&2; exit 1; fi
grep -Fq 'host-runtime' "${work}/output"
cat > "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh" <<'HELPER'
ort_host_runtime_needed() {
  case "${STUB_BAD:-0}" in
    1) printf 'libcuda.so.*\n' ;;
    2) printf 'libamdhip64.so.7\n'; return 1 ;;
    3) return 0 ;;
    *) printf 'libmigraphx_c.so.3\nlibamdhip64.so.7\n' ;;
  esac
}
ort_assert_no_bundled_host_runtime() {
  [ ! -e "$1/lib/libmigraphx_c.so.3" ] || { echo 'host GPU runtime library was bundled' >&2; return 1; }
}
HELPER
if check amd Linux x86_64 ON ON; then echo 'incomplete shared CPack API unexpectedly accepted' >&2; exit 1; fi
printf 'NO_DEFAULT_SYSTEM\n' >> "${work}/hub/cmake/CPackCommon.cmake"
if check amd Linux x86_64 ON ON; then echo 'AppImage ORT preservation unexpectedly missing' >&2; exit 1; fi
printf 'PRESERVE_ORT_IN_APPIMAGE\n' >> "${work}/hub/cmake/CPackCommon.cmake"
check amd Linux x86_64 ON ON || { cat "${work}/output" >&2; exit 1; }

mkdir -p "${work}/project" "${work}/install/lib"
cat > "${work}/project/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.24)
project(host_runtime_guard NONE)
include("${MODULE}")
accelerantgine_gpu_host_dependencies("${HELPER}" "${PROVIDER}" "${KIND}" actual)
if(NOT actual STREQUAL EXPECTED)
  message(FATAL_ERROR "Wrong host SONAMEs: ${actual}")
endif()
file(READ "${CPACK}" cpack_source)
string(FIND "${cpack_source}" "kataglyphis_install_linux_closure(" closure)
string(FIND "${cpack_source}" "accelerantgine_install_gpu_host_runtime_guard(" guard)
string(FIND "${cpack_source}" "\${PROJECT_NAME}_demo" demo)
if(closure LESS 0 OR guard LESS closure OR demo LESS closure OR demo GREATER guard)
  message(FATAL_ERROR "The demo must be in the closure before the host-runtime guard")
endif()
accelerantgine_install_gpu_host_runtime_guard("${HELPER}" "${KIND}")
CMAKE
helper="${ORT_TEST_HELPER:-${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh}"
provider="${ORT_TEST_PROVIDER:-${work}/provider.so}"
kind="${ORT_TEST_KIND:-migraphx}"
expected="${ORT_TEST_EXPECTED:-libmigraphx_c.so.3;libamdhip64.so.7}"
vendor="${ORT_TEST_VENDOR_SONAME:-libmigraphx_c.so.3}"
configure_guard() {
  cmake -S "${work}/project" -B "$1" "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" \
    "-DCPACK=${root}/cmake/CPackOptions.cmake" "-DHELPER=${helper}" "-DPROVIDER=${provider}" \
    "-DKIND=${kind}" "-DEXPECTED=${expected}" >"${work}/output" 2>&1
}
configure_guard "${work}/build" || { cat "${work}/output" >&2; exit 1; }
# shellcheck disable=SC2016 # Match the literal CMake variable.
sed '/^[[:space:]]*${PROJECT_NAME}_demo[[:space:]]*$/d' "${root}/cmake/CPackOptions.cmake" > "${work}/without-demo.cmake"
if cmake -S "${work}/project" -B "${work}/without-demo-build" "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" \
    "-DCPACK=${work}/without-demo.cmake" "-DHELPER=${helper}" "-DPROVIDER=${provider}" \
    "-DKIND=${kind}" "-DEXPECTED=${expected}" >"${work}/output" 2>&1; then
  echo 'closure without the inference demo unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'demo must be in the closure' "${work}/output"
cmake --install "${work}/build" --prefix "${work}/install" >"${work}/output" 2>&1 || { cat "${work}/output" >&2; exit 1; }
touch "${work}/install/lib/${vendor}"
if cmake --install "${work}/build" --prefix "${work}/install" >"${work}/output" 2>&1; then
  echo 'bundled host GPU runtime unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'host GPU runtime library was bundled' "${work}/output"
if [ -z "${ORT_TEST_HELPER:-}" ]; then
  if STUB_BAD=1 configure_guard "${work}/bad-build"; then echo 'wildcard host dependency unexpectedly accepted' >&2; exit 1; fi
  grep -Fq 'Invalid host-runtime dependency' "${work}/output"
  for failure in 2 3; do
    if STUB_BAD="${failure}" configure_guard "${work}/bad-build-${failure}"; then
      echo 'failed or empty host dependency query unexpectedly accepted' >&2; exit 1
    fi
    grep -Fq 'Cannot identify migraphx provider host-runtime dependencies' "${work}/output"
  done
fi
mkdir -p "${work}/hook/third_party/ANTfrastructure/linux/scripts/06-packaging"
cat > "${work}/hook/third_party/ANTfrastructure/linux/scripts/06-packaging/verify-ort-appimage-payload.sh" <<'VERIFY'
#!/usr/bin/env bash
exit "${MOCK_APPIMAGE_FAILURE:-0}"
VERIFY
cat > "${work}/hook/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.24)
project(appimage_postbuild NONE)
set(_gpu_wheels /fixture/wheels)
set(_gpu_strip strip)
set(CMAKE_INSTALL_LIBDIR lib)
set(KATAGLYPHIS_ORT_VARIANT amd)
configure_file("${TEMPLATE}" "${CMAKE_BINARY_DIR}/VerifyGpuAppImage.cmake" @ONLY)
CMAKE
cmake -S "${work}/hook" -B "${work}/hook-build" "-DTEMPLATE=${root}/cmake/VerifyGpuAppImage.cmake.in" >"${work}/output" 2>&1
post_check() {
  cmake "-DCPACK_PACKAGE_FILES=$1" "-DCPACK_GENERATOR=$2" -P "${work}/hook-build/VerifyGpuAppImage.cmake" >"${work}/output" 2>&1
}
post_check "${work}/test.AppImage" AppImage || { cat "${work}/output" >&2; exit 1; }
if MOCK_APPIMAGE_FAILURE=1 post_check "${work}/test.AppImage" AppImage; then
  echo 'A failed final AppImage verification unexpectedly passed CPack' >&2; exit 1
fi
post_check "${work}/test.deb" DEB || { cat "${work}/output" >&2; exit 1; }
if post_check "${work}/test.deb" AppImage; then
  echo 'AppImage generation without a finished AppImage unexpectedly passed' >&2; exit 1
fi
echo 'ORT package matrix and shared API checks passed'
