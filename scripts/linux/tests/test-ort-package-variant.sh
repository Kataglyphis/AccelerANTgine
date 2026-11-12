#!/usr/bin/env bash
# Checks matrix, shared API and install-guard wiring; it does not run GPU inference.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
if LC_ALL=C grep -q $'\r' "${root}/resources/packaging/AccelerANTgine.desktop"; then
  echo 'The AppImage desktop file must use LF line endings' >&2; exit 1
fi
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
cp "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh" "${work}/helper-without-plugin-api"
cat >> "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh" <<'HELPER'
ORT_AMDGPU_EP_MODULE=libmigraphx-ep.so
ort_amdgpu_ep_dir() { printf '%s/lib' "${ORT_AMDGPU_EP_ROOT:-/usr/local/lib/onnxruntime-ep-amdgpu}"; }
ort_assert_plugin_module() {
  cmp -s "$1" "$(ort_amdgpu_ep_dir)/${ORT_AMDGPU_EP_MODULE}" || { echo "$1 is not the image's module" >&2; return 1; }
}
HELPER
if check amd Linux x86_64 ON ON; then echo 'incomplete shared CPack API unexpectedly accepted' >&2; exit 1; fi
printf 'NO_DEFAULT_SYSTEM\n' >> "${work}/hub/cmake/CPackCommon.cmake"
if check amd Linux x86_64 ON ON; then echo 'AppImage ORT preservation unexpectedly missing' >&2; exit 1; fi
printf 'PRESERVE_ORT_IN_APPIMAGE\n' >> "${work}/hub/cmake/CPackCommon.cmake"
check amd Linux x86_64 ON ON || { cat "${work}/output" >&2; exit 1; }
# Everything else is in place here, so only the missing plugin module API can refuse this hub.
cp "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh" "${work}/helper-with-plugin-api"
cp "${work}/helper-without-plugin-api" "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh"
if check amd Linux x86_64 ON ON; then echo 'a hub without the plugin module API unexpectedly accepted' >&2; exit 1; fi
grep -Fq 'plugin MIGraphX module' "${work}/output"
cp "${work}/helper-with-plugin-api" "${work}/hub/linux/scripts/06-packaging/ort-runtime-bundle.sh"

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
if(closure LESS 0 OR guard LESS closure)
  message(FATAL_ERROR "The demo must be in the closure before the host-runtime guard")
endif()
string(SUBSTRING "${cpack_source}" ${closure} -1 closure_source)
string(FIND "${closure_source}" "\n  TARGETS\n" targets_begin)
string(FIND "${closure_source}" "\n  SEARCH\n" targets_end)
math(EXPR targets_end_absolute "${closure} + ${targets_end}")
if(targets_begin LESS 0 OR targets_end LESS targets_begin OR targets_end_absolute GREATER guard)
  message(FATAL_ERROR "The closure TARGETS section is missing")
endif()
math(EXPR targets_length "${targets_end} - ${targets_begin}")
string(SUBSTRING "${closure_source}" ${targets_begin} ${targets_length} closure_targets)
string(FIND "${closure_targets}" "\${PROJECT_NAME}_demo" demo)
if(demo LESS 0)
  message(FATAL_ERROR "The demo must be in the closure before the host-runtime guard")
endif()
string(FIND "${closure_source}" "\n  PROTECT\n" protect_begin)
string(FIND "${closure_source}" ")" closure_end)
if(protect_begin LESS 0 OR closure_end LESS protect_begin)
  message(FATAL_ERROR "The closure PROTECT section is missing")
endif()
math(EXPR protect_length "${closure_end} - ${protect_begin}")
string(SUBSTRING "${closure_source}" ${protect_begin} ${protect_length} closure_protect)
string(FIND "${closure_protect}" "\${_gpu_protect}" protected)
string(FIND "${closure_source}" "accelerantgine_keep_module_in_appimage(" kept)
string(FIND "${closure_source}" "accelerantgine_install_plugin_module_proof(" proved)
string(FIND "${closure_source}" "include(CPack)" cpack)
if(protected LESS 0 OR kept LESS closure_end OR proved LESS closure_end OR cpack LESS kept)
  message(FATAL_ERROR "The plugin module must be protected in the closure, kept in the AppImage and proved after both")
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
suite_refuses_logged 'closure without the inference demo unexpectedly accepted' 'demo must be in the closure' "${work}/output" \
  cmake -S "${work}/project" -B "${work}/without-demo-build" "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" \
    "-DCPACK=${work}/without-demo.cmake" "-DHELPER=${helper}" "-DPROVIDER=${provider}" \
    "-DKIND=${kind}" "-DEXPECTED=${expected}"
cmake --install "${work}/build" --prefix "${work}/install" >"${work}/output" 2>&1 || { cat "${work}/output" >&2; exit 1; }
touch "${work}/install/lib/${vendor}"
suite_refuses_logged 'bundled host GPU runtime unexpectedly accepted' 'host GPU runtime library was bundled' "${work}/output" \
  cmake --install "${work}/build" --prefix "${work}/install"
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

# The plugin module: found through the hub's own names, kept from CPack's AppImage patching and proved at install.
mkdir -p "${work}/plugin" "${work}/ep/lib" "${work}/package/lib/accelerantgine"
cat > "${work}/plugin/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.24)
project(plugin_module NONE)
include("${MODULE}")
accelerantgine_amdgpu_ep_module("${HELPER}" module)
if(NOT module STREQUAL EXPECTED)
  message(FATAL_ERROR "Wrong plugin module: ${module}")
endif()
set(CPACK_APPIMAGE_PATCHELF_EXECUTABLE "${INNER}")
accelerantgine_keep_module_in_appimage(libmigraphx-ep.so CPACK_APPIMAGE_PATCHELF_EXECUTABLE)
file(WRITE "${CMAKE_BINARY_DIR}/wrapper-path" "${CPACK_APPIMAGE_PATCHELF_EXECUTABLE}")
accelerantgine_install_plugin_module_proof("${HELPER}" "lib/accelerantgine/libmigraphx-ep.so")
CMAKE
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "${work}/patched" > "${work}/inner-patchelf"
chmod +x "${work}/inner-patchelf"
# Usage: configure_plugin BUILD_DIR HELPER [INNER]; the image's plugin root is ${work}/ep.
configure_plugin() {
  ORT_AMDGPU_EP_ROOT="${work}/ep" cmake -S "${work}/plugin" -B "$1" "-DMODULE=${root}/cmake/OrtPackageVariant.cmake" \
    "-DHELPER=$2" "-DEXPECTED=${work}/ep/lib/libmigraphx-ep.so" "-DINNER=${3-${work}/inner-patchelf}" >"${work}/output" 2>&1
}
real_helper="${root}/third_party/ANTfrastructure/linux/scripts/06-packaging/ort-runtime-bundle.sh"
suite_refuses_logged 'an image without the plugin module unexpectedly accepted' "requires the image's plugin MIGraphX module" \
  "${work}/output" configure_plugin "${work}/plugin-missing" "${real_helper}"
printf 'image module\n' > "${work}/ep/lib/libmigraphx-ep.so"
configure_plugin "${work}/plugin-build" "${real_helper}" || { cat "${work}/output" >&2; exit 1; }
suite_refuses_logged 'an AppImage step without a patchelf wrapper unexpectedly accepted' 'must be set before' \
  "${work}/output" configure_plugin "${work}/plugin-no-wrapper" "${real_helper}" ''
wrapper="$(cat "${work}/plugin-build/wrapper-path")"
"${wrapper}" --set-rpath '$ORIGIN' /bundle/usr/lib/accelerantgine/libmigraphx-ep.so
[[ ! -e "${work}/patched" ]] || { echo "CPack's AppImage step would patch the plugin module" >&2; exit 1; }
"${wrapper}" --set-rpath '$ORIGIN' /bundle/usr/lib/accelerantgine/libfoo.so
[[ "$(cat "${work}/patched")" == '--set-rpath $ORIGIN /bundle/usr/lib/accelerantgine/libfoo.so' ]] || {
  echo 'The AppImage patchelf wrapper did not pass another library on' >&2; exit 1;
}
cp "${work}/ep/lib/libmigraphx-ep.so" "${work}/package/lib/accelerantgine/"
install_plugin() { ORT_AMDGPU_EP_ROOT="${work}/ep" cmake --install "${work}/plugin-build" --prefix "${work}/package"; }
install_plugin >"${work}/output" 2>&1 || { cat "${work}/output" >&2; exit 1; }
printf 'patched\n' >> "${work}/package/lib/accelerantgine/libmigraphx-ep.so"
suite_refuses_logged "a staged module that is not the image's unexpectedly accepted" "is not the image's" "${work}/output" install_plugin
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
bash "${root}/scripts/linux/tests/test-demo-device.sh"
echo 'ORT package matrix and shared API checks passed'
