#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/source/scripts/linux"
ln -s "$repo/scripts/linux/isolate-package-gstreamer.sh" "$work/source/scripts/linux/"
cat > "$work/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.24)
project(AccelerANTgine C)
include(GNUInstallDirs)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/main.c" "int main(void) { return 0; }\n")
if(NOT OMIT_CLI)
  add_executable(AccelerANTgine_cli "${CMAKE_CURRENT_BINARY_DIR}/main.c")
  set_target_properties(AccelerANTgine_cli PROPERTIES OUTPUT_NAME AccelerANTgine)
endif()
if(NOT OMIT_DEMO)
  add_executable(AccelerANTgine_demo "${CMAKE_CURRENT_BINARY_DIR}/main.c")
endif()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/launcher" "#!/bin/bash\n[ -z \"\${GST_PLUGIN_PATH_1_0+x}\" ]\n")
if(NOT OMIT_CLI)
  install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/launcher" DESTINATION bin RENAME AccelerANTgine)
endif()
if(NOT OMIT_DEMO)
  install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/launcher" DESTINATION bin RENAME AccelerANTgine_demo)
endif()
file(READ "${SOURCE_ROOT}/cmake/CPackOptions.cmake" _source)
string(FIND "${_source}" "if(PROJECT_IS_TOP_LEVEL AND CMAKE_SYSTEM_NAME STREQUAL \"Linux\")\n  set(_gst_launchers" _start)
if(_start LESS 0)
  message(FATAL_ERROR "Package isolation block not found")
endif()
string(SUBSTRING "${_source}" ${_start} -1 _tail)
string(FIND "${_tail}" "\nif(PROJECT_IS_TOP_LEVEL AND _gpu_provider)" _end)
if(_end LESS 0)
  message(FATAL_ERROR "Package isolation block end not found")
endif()
string(SUBSTRING "${_tail}" 0 ${_end} _block)
cmake_language(EVAL CODE "${_block}")
CMAKE
for kind in full no-demo library-only; do
  options=()
  [[ $kind != no-demo ]] || options=(-DOMIT_DEMO=ON)
  [[ $kind != library-only ]] || options=(-DOMIT_CLI=ON -DOMIT_DEMO=ON)
  cmake -S "$work/source" -B "$work/$kind" -DSOURCE_ROOT="$repo" "${options[@]}" >/dev/null
  DESTDIR="$work/stage-$kind" cmake --install "$work/$kind" --prefix /usr >/dev/null
  if [[ $kind != library-only ]]; then env GST_PLUGIN_PATH_1_0=/host "$work/stage-$kind/usr/bin/AccelerANTgine"; fi
  if [[ $kind == full ]]; then env GST_PLUGIN_PATH_1_0=/host "$work/stage-$kind/usr/bin/AccelerANTgine_demo"; fi
  if [[ $kind == library-only ]]; then [[ ! -e "$work/stage-$kind/usr/bin/AccelerANTgine" ]]; fi
done
echo 'CMake installs isolated package launchers for full, CLI-only and library-only builds'
