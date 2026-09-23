# # we depend on vulkan
# find_package(Vulkan REQUIRED)
# # configure vulkan version
# set(VULKAN_VERSION_MAJOR 1)
# set(VULKAN_VERSION_MINOR 3)
find_package(Threads REQUIRED)

# # we depend on OpenGL
# find_package(OpenGL REQUIRED COMPONENTS OpenGL)
# # configure OpenGL version
# set(OPENGL_VERSION_MAJOR 4)
# set(OPENGL_VERSION_MINOR 6)
# set(OpenGL_GL_PREFERENCE GLVND)

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

# ONNX Runtime: the family's chain build ONLY (ANTfrastructure owner rule
# 2026-09-23). One prefix is searched - ONNXRUNTIME_ROOT if given, else the image's
# ($ENV{ONNX_ROOT} on Windows, /usr/local/lib/onnxruntime-cpu on Linux) - and it is
# REQUIRED: no system, vendor, vcpkg or pkg-config fallback, and a runtime library
# that does not embed the chain's ORT source root is refused. Not covered: which
# copy the OS loader picks at run time; the packaging lanes stage the chain one.
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

# ORT embeds its source paths; the chain's checkout is the hub's Build-OnnxFromSource.ps1
# SourceDir (Windows) and onnxruntime/build/lib/common.sh ORT_SRC_DIR (Linux).
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

# The proven chain ORT installs beside the exe, so every CPack installer carries it (else a client
# loads System32's Windows ML copy). Build-Windows.ps1 runs G6 over the install tree before packing.
if(WIN32)
  set(_ort_install_files "${_ort_runtime}")
  foreach(_ort_companion onnxruntime_providers_shared.dll DirectML.dll)
    if(EXISTS "${_ort_root}/bin/${_ort_companion}")
      list(APPEND _ort_install_files "${_ort_root}/bin/${_ort_companion}")
    endif()
  endforeach()
  install(FILES ${_ort_install_files} DESTINATION ${CMAKE_INSTALL_BINDIR})
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
