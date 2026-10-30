find_package(Threads REQUIRED)

# GStreamer dependencies
set(GSTREAMER_ROOT
    "/opt/gstreamer"
    CACHE PATH "GStreamer installation root")

if(EXISTS "${GSTREAMER_ROOT}")
  set(PKG_CONFIG_PATH
      "${GSTREAMER_ROOT}/lib/aarch64-linux-gnu/pkgconfig:${GSTREAMER_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH}"
      CACHE INTERNAL "GStreamer pkg-config path")
  set(CMAKE_PREFIX_PATH "${GSTREAMER_ROOT};${CMAKE_PREFIX_PATH}")

  set(ENV{PKG_CONFIG_PATH}
      "${GSTREAMER_ROOT}/lib/aarch64-linux-gnu/pkgconfig:${GSTREAMER_ROOT}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
endif()

find_package(PkgConfig REQUIRED)

pkg_check_modules(
  GSTREAMER
  REQUIRED
  IMPORTED_TARGET
  gstreamer-1.0>=1.24
  gstreamer-app-1.0>=1.24
  gstreamer-video-1.0>=1.24
  gstreamer-analytics-1.0>=1.24
  gstreamer-webrtc-1.0>=1.24
  gstreamer-sdp-1.0>=1.24)

pkg_check_modules(
  GLIB
  REQUIRED
  IMPORTED_TARGET
  glib-2.0>=2.70)

# ONNX Runtime: the family's chain build only, from one prefix, with no system, vendor or pkg-config fallback.
set(KATAGLYPHIS_ORT_VARIANT
    "cpu"
    CACHE STRING "Package ONNX Runtime variant: cpu, nvidia or amd")
set_property(
  CACHE KATAGLYPHIS_ORT_VARIANT
  PROPERTY STRINGS
           cpu
           nvidia
           amd)
include(OrtPackageVariant)
accelerantgine_validate_ort_package_variant(
  "${KATAGLYPHIS_ORT_VARIANT}"
  "${CMAKE_SYSTEM_NAME}"
  "${CMAKE_SYSTEM_PROCESSOR}"
  "${PROJECT_IS_TOP_LEVEL}")
set(ONNXRUNTIME_ROOT
    ""
    CACHE PATH "Chain-built ONNX Runtime prefix (default: the family image's)")

if(ONNXRUNTIME_ROOT)
  set(_ort_root "${ONNXRUNTIME_ROOT}")
elseif(WIN32)
  if(NOT DEFINED ENV{ONNX_ROOT} OR "$ENV{ONNX_ROOT}" STREQUAL "")
    message(
      FATAL_ERROR
        "ONNX Runtime: ONNX_ROOT is not set. Build inside the family Windows image, or pass -DONNXRUNTIME_ROOT=<a chain-built ORT prefix>."
    )
  endif()
  set(_ort_root "$ENV{ONNX_ROOT}")
elseif(
  NOT
  KATAGLYPHIS_ORT_VARIANT
  STREQUAL
  "cpu")
  set(_ort_root "/usr/local/lib/onnxruntime-gpu")
else()
  set(_ort_root "/usr/local/lib/onnxruntime-cpu")
endif()
file(TO_CMAKE_PATH "${_ort_root}" _ort_root)

# A cached hit from an earlier configure must not outlive a prefix change.
unset(_ONNXRUNTIME_LIB CACHE)
unset(_ONNXRUNTIME_INCLUDE_DIR CACHE)
find_library(
  _ONNXRUNTIME_LIB
  NAMES onnxruntime
  PATHS "${_ort_root}/lib"
  NO_DEFAULT_PATH)
find_path(
  _ONNXRUNTIME_INCLUDE_DIR
  NAMES onnxruntime_cxx_api.h
  PATHS "${_ort_root}/include" "${_ort_root}/include/onnxruntime" "${_ort_root}/include/onnxruntime/core/session"
  NO_DEFAULT_PATH)
if(NOT _ONNXRUNTIME_LIB OR NOT _ONNXRUNTIME_INCLUDE_DIR)
  message(
    FATAL_ERROR
      "ONNX Runtime: no chain-built ORT under ${_ort_root} (library: ${_ONNXRUNTIME_LIB}, headers: ${_ONNXRUNTIME_INCLUDE_DIR}). Only the family image's chain build is allowed; nothing else is searched."
  )
endif()

# ORT embeds its source paths, so the chain build's checkout directory proves where a binary came from.
if(WIN32)
  set(_ort_runtime "${_ort_root}/bin/onnxruntime.dll")
  set(_ort_chain_marker "temp.onnx-src.onnxruntime.core.")
else()
  get_filename_component(_ort_runtime "${_ONNXRUNTIME_LIB}" REALPATH)
  set(_ort_chain_marker "/opt/onnxruntime/onnxruntime/core/")
endif()
if(NOT EXISTS "${_ort_runtime}")
  message(
    FATAL_ERROR "ONNX Runtime: ${_ort_runtime} is missing, so ${_ort_root} cannot be proved to be the chain build.")
endif()
file(
  STRINGS "${_ort_runtime}" _ort_chain_hit
  LIMIT_COUNT 1
  REGEX "${_ort_chain_marker}")
if(NOT _ort_chain_hit)
  message(
    FATAL_ERROR
      "ONNX Runtime: ${_ort_runtime} is not the family's chain build (no '${_ort_chain_marker}' source path in it). A downloaded, distro or vendor ORT is not allowed."
  )
endif()

set(ONNXRUNTIME_FOUND TRUE)
set(ONNXRUNTIME_LIBRARY "${_ONNXRUNTIME_LIB}")
set(ONNXRUNTIME_INCLUDE_DIR "${_ONNXRUNTIME_INCLUDE_DIR}")
message(STATUS "Found chain-built ONNX Runtime at: ${_ort_root}")
message(STATUS "  Library: ${_ONNXRUNTIME_LIB}")
message(STATUS "  Headers: ${_ONNXRUNTIME_INCLUDE_DIR}")

# Installed beside the exe, or a client loads System32's Windows ML onnxruntime.dll instead.
if(WIN32)
  set(_ort_install_files "${_ort_runtime}")
  foreach(_ort_companion onnxruntime_providers_shared.dll DirectML.dll)
    if(KATAGLYPHIS_ORT_VARIANT STREQUAL "cpu")
      set(_ort_companion_path "${_ort_root}/bin/${_ort_companion}")
    else()
      accelerantgine_find_windows_ort_file("${_ort_root}" "${_ort_companion}" _ort_companion_path)
    endif()
    if(EXISTS "${_ort_companion_path}" AND NOT IS_DIRECTORY "${_ort_companion_path}")
      list(APPEND _ort_install_files "${_ort_companion_path}")
    endif()
  endforeach()
  if(PROJECT_IS_TOP_LEVEL AND KATAGLYPHIS_ORT_VARIANT STREQUAL "nvidia")
    accelerantgine_find_windows_ort_file("${_ort_root}" "onnxruntime_providers_cuda.dll" _ort_cuda)
    accelerantgine_find_windows_ort_file("${_ort_root}" "onnxruntime_providers_shared.dll" _ort_shared)
    if(NOT _ort_cuda OR NOT _ort_shared)
      message(FATAL_ERROR "NVIDIA packages require the chain CUDA provider and its shared bridge")
    endif()
    list(APPEND _ort_install_files "${_ort_cuda}")
  elseif(PROJECT_IS_TOP_LEVEL AND KATAGLYPHIS_ORT_VARIANT STREQUAL "amd")
    accelerantgine_find_windows_ort_file("${_ort_root}" "DirectML.dll" _ort_directml)
    accelerantgine_find_windows_ort_file("${_ort_root}" "onnxruntime_providers_shared.dll" _ort_shared)
    if(NOT _ort_directml OR NOT _ort_shared)
      message(FATAL_ERROR "AMD Windows packages require the chain DirectML redistributable and shared provider bridge")
    endif()
  endif()
  install(FILES ${_ort_install_files} DESTINATION ${CMAKE_INSTALL_BINDIR})
  if(PROJECT_IS_TOP_LEVEL AND KATAGLYPHIS_PACKAGE_DLL_DIR)
    install(FILES "${KATAGLYPHIS_PACKAGE_DLL_DIR}/licenses/onnxruntime/LICENSE"
                  "${KATAGLYPHIS_PACKAGE_DLL_DIR}/licenses/onnxruntime/ThirdPartyNotices.txt"
            DESTINATION "licenses/onnxruntime")
  endif()
endif()

# GStreamer and ONNX Runtime are now linked via IMPORTED_TARGET in Src/CMakeLists.txt

add_library(onnxruntime::onnxruntime UNKNOWN IMPORTED)
set_target_properties(onnxruntime::onnxruntime PROPERTIES IMPORTED_LOCATION "${ONNXRUNTIME_LIBRARY}"
                                                          INTERFACE_INCLUDE_DIRECTORIES "${ONNXRUNTIME_INCLUDE_DIR}")
# Add additional include directories for nested header structure
if(EXISTS "${_ort_root}/include/onnxruntime/core/session")
  target_include_directories(onnxruntime::onnxruntime INTERFACE "${_ort_root}/include/onnxruntime/core/session")
endif()
if(EXISTS "${_ort_root}/include/onnxruntime/core/providers/cpu")
  target_include_directories(onnxruntime::onnxruntime INTERFACE "${_ort_root}/include/onnxruntime/core/providers/cpu")
endif()
message(STATUS "ONNX Runtime imported target created successfully")

# ONNX Runtime GenAI: its C header only; Src/text_generation.cpp loads the chain library at run time.
set(ONNXRUNTIME_GENAI_ROOT
    ""
    CACHE PATH "Chain-built ONNX Runtime GenAI prefix (default: the family image's)")
if(ONNXRUNTIME_GENAI_ROOT)
  set(_genai_root "${ONNXRUNTIME_GENAI_ROOT}")
elseif(WIN32)
  if(NOT DEFINED ENV{ONNX_GENAI_ROOT} OR "$ENV{ONNX_GENAI_ROOT}" STREQUAL "")
    message(
      FATAL_ERROR
        "ONNX Runtime GenAI: ONNX_GENAI_ROOT is not set. Build inside the family Windows image, or pass -DONNXRUNTIME_GENAI_ROOT=<a chain-built GenAI prefix>."
    )
  endif()
  set(_genai_root "$ENV{ONNX_GENAI_ROOT}")
else()
  set(_genai_root "/usr/local/lib/onnxruntime-genai")
endif()
file(TO_CMAKE_PATH "${_genai_root}" _genai_root)
unset(_ONNXRUNTIME_GENAI_INCLUDE_DIR CACHE)
find_path(
  _ONNXRUNTIME_GENAI_INCLUDE_DIR
  NAMES ort_genai_c.h
  PATHS "${_genai_root}/include" "${_genai_root}"
  NO_DEFAULT_PATH)
if(NOT _ONNXRUNTIME_GENAI_INCLUDE_DIR)
  message(
    FATAL_ERROR
      "ONNX Runtime GenAI: no ort_genai_c.h under ${_genai_root}. Only the family image's chain build is allowed; nothing else is searched."
  )
endif()
add_library(onnxruntime_genai::headers INTERFACE IMPORTED)
set_target_properties(onnxruntime_genai::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES
                                                            "${_ONNXRUNTIME_GENAI_INCLUDE_DIR}")
message(STATUS "Found chain-built ONNX Runtime GenAI headers at: ${_ONNXRUNTIME_GENAI_INCLUDE_DIR}")
