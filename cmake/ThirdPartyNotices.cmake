# Third-party notices for every installed tree; the inventory and its gate: docs/source/third_party_licenses.rst.
include_guard(GLOBAL)
include(FetchContent)

get_filename_component(_ACCELERANTGINE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(_ACCELERANTGINE_NOTICES_SCRIPT "${_ACCELERANTGINE_ROOT}/scripts/packaging/third_party_notices.py")
set(_ACCELERANTGINE_NOTICES_MANIFEST "${_ACCELERANTGINE_ROOT}/packaging/third-party/components.json")
set(_ACCELERANTGINE_HUB "${_ACCELERANTGINE_ROOT}/third_party/ANTfrastructure")

# The Cargo half: crates the Rust static library links, collected by ANTfrastructure's tool.
function(_accelerantgine_cargo_notice_args out_var)
  if(NOT Rust_CARGO_TARGET_CACHED OR NOT Rust_CARGO_CACHED)
    message(FATAL_ERROR "Third-party notices need Corrosion's Rust_CARGO_TARGET_CACHED and Rust_CARGO_CACHED.")
  endif()
  set(${out_var}
      --cargo-stager
      "${_ACCELERANTGINE_HUB}/linux/scripts/06-packaging/stage-cargo-licenses.py"
      --cargo-workspace
      "${_ACCELERANTGINE_ROOT}/Src/rusty_code"
      --cargo-root-package
      rusty_code
      --cargo-target
      "${Rust_CARGO_TARGET_CACHED}"
      --cargo-policy
      "${_ACCELERANTGINE_ROOT}/packaging/third-party/cargo-license-policy.json"
      PARENT_SCOPE)
endfunction()

# Quotes each argument for an install(CODE) execute_process; the install root stays a run-time variable.
function(_accelerantgine_quote_args out_var)
  set(_quoted "")
  foreach(_arg IN LISTS ARGN)
    string(APPEND _quoted " \"${_arg}\"")
  endforeach()
  set(${out_var}
      "${_quoted}"
      PARENT_SCOPE)
endfunction()

function(
  _accelerantgine_notices_install_code
  out_var
  platform
  root_expr
  dest_rel
  license_rel)
  find_package(
    Python3
    COMPONENTS Interpreter
    REQUIRED)
  FetchContent_GetProperties(abseil-cpp)
  if(NOT abseil-cpp_SOURCE_DIR)
    message(FATAL_ERROR "Third-party notices need abseil-cpp's source directory for its license.")
  endif()
  _accelerantgine_cargo_notice_args(_cargo)
  get_filename_component(_cargo_dir "${Rust_CARGO_CACHED}" DIRECTORY)
  _accelerantgine_quote_args(
    _fixed
    "${_ACCELERANTGINE_NOTICES_SCRIPT}"
    --manifest
    "${_ACCELERANTGINE_NOTICES_MANIFEST}"
    --platform
    "${platform}"
    --repo
    "${_ACCELERANTGINE_ROOT}"
    --project
    "${PROJECT_NAME}"
    --project-license
    "${license_rel}"
    --versions-env
    "${_ACCELERANTGINE_HUB}/linux/scripts/01-core/versions.env"
    --text-root
    "abseil=${abseil-cpp_SOURCE_DIR}"
    ${_cargo}
    ${ARGN})
  if(CMAKE_HOST_WIN32)
    set(_sep ";")
  else()
    set(_sep ":")
  endif()
  # cargo runs offline from the build's CARGO_HOME, so its directory must be on PATH.
  set(${out_var}
      "set(_kg_root \"${root_expr}\")
set(ENV{PATH} \"${_cargo_dir}${_sep}\$ENV{PATH}\")
execute_process(COMMAND \"${Python3_EXECUTABLE}\"${_fixed} --root \"\${_kg_root}\" --dest \"\${_kg_root}/${dest_rel}\" COMMAND_ERROR_IS_FATAL ANY)
"
      PARENT_SCOPE)
endfunction()

# Windows packages ship the DLL closure Build-Windows.ps1 stages, so only that build can list it.
function(accelerantgine_install_windows_notices)
  if(NOT WIN32 OR NOT PROJECT_IS_TOP_LEVEL)
    return()
  endif()
  if(NOT KATAGLYPHIS_PACKAGE_DLL_DIR)
    message(STATUS "Third-party notices: no KATAGLYPHIS_PACKAGE_DLL_DIR, so no packaged closure to list")
    return()
  endif()
  _accelerantgine_notices_install_code(
    _code
    windows
    "\${CMAKE_INSTALL_PREFIX}"
    licenses
    "share/licenses/${PROJECT_NAME}/LICENSE")
  install(CODE "${_code}")
endfunction()

# Runs after the ELF closure, so it lists what each Linux generator is about to pack.
function(accelerantgine_install_linux_notices)
  if(NOT
     CMAKE_SYSTEM_NAME
     STREQUAL
     "Linux"
     OR NOT PROJECT_IS_TOP_LEVEL)
    return()
  endif()
  cmake_parse_arguments(
    ARG
    ""
    ""
    "SEARCH"
    ${ARGN})
  find_package(
    Python3
    COMPONENTS Interpreter
    REQUIRED)
  execute_process(
    COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=libstdc++.so.6
    OUTPUT_VARIABLE _libstdcxx
    OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  set(_search_dirs ${ARG_SEARCH})
  # The closure takes the compiler's libstdc++, which a distro copy later in the search would misattribute.
  if(IS_ABSOLUTE "${_libstdcxx}")
    get_filename_component(_compiler_runtime_dir "${_libstdcxx}" DIRECTORY)
    list(PREPEND _search_dirs "${_compiler_runtime_dir}")
  endif()
  set(_search_args "")
  foreach(_dir IN LISTS _search_dirs)
    list(
      APPEND
      _search_args
      --search
      "${_dir}")
  endforeach()
  if(DEFINED ENV{ORT_CHAIN_WHEEL_DIR})
    set(_ort_wheels "$ENV{ORT_CHAIN_WHEEL_DIR}")
  else()
    set(_ort_wheels "/opt/onnxruntime-wheels")
  endif()
  if(CMAKE_STRIP)
    set(_strip "${CMAKE_STRIP}")
  else()
    set(_strip strip)
  endif()
  _accelerantgine_notices_install_code(
    _code
    linux
    "\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}"
    "share/licenses/${PROJECT_NAME}"
    "share/licenses/${PROJECT_NAME}/LICENSE"
    --dpkg
    dpkg
    ${_search_args})
  get_filename_component(_ort_chain_dir "${_ONNXRUNTIME_LIB}" DIRECTORY)
  set(_ort_stager "${_ACCELERANTGINE_ROOT}/scripts/packaging/stage_ort_texts.py")
  set(_ort_wheel_stager "${_ACCELERANTGINE_HUB}/linux/scripts/06-packaging/stage-ort-wheel-licenses.py")
  # ONNX Runtime's own texts, tied to the bundled library: scripts/packaging/stage_ort_texts.py says how.
  install(
    CODE "set(_kg_root \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\")
file(GLOB _kg_ort LIST_DIRECTORIES false \"\${_kg_root}/${CMAKE_INSTALL_LIBDIR}/accelerantgine/libonnxruntime.so.*\")
list(LENGTH _kg_ort _kg_ort_count)
if(NOT _kg_ort_count EQUAL 1)
  message(FATAL_ERROR \"Expected one bundled libonnxruntime.so.*, found: \${_kg_ort}\")
endif()
execute_process(COMMAND \"${Python3_EXECUTABLE}\" \"${_ort_stager}\" --library \"\${_kg_ort}\" --chain-dir \"${_ort_chain_dir}\"
  --wheel-dir \"${_ort_wheels}\" --wheel-stager \"${_ort_wheel_stager}\" --strip \"${_strip}\"
  --destination \"\${_kg_root}/share/licenses/onnxruntime\" COMMAND_ERROR_IS_FATAL ANY)
")
  install(CODE "${_code}")
endfunction()

# The wheel carries the project license and the notices of what its two binaries link statically.
function(accelerantgine_install_wheel_notices component)
  if(NOT PROJECT_IS_TOP_LEVEL)
    return()
  endif()
  if(WIN32)
    set(_platform windows)
  else()
    set(_platform linux)
  endif()
  install(
    FILES "${_ACCELERANTGINE_ROOT}/LICENSE"
    DESTINATION kataglyphis_inference/licenses
    COMPONENT ${component})
  _accelerantgine_notices_install_code(
    _code
    ${_platform}
    "\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/kataglyphis_inference"
    licenses
    licenses/LICENSE
    --scope
    wheel)
  install(CODE "${_code}" COMPONENT ${component})
endfunction()
