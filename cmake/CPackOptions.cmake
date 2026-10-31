# Only this project's identity; the CPack wiring is ANTfrastructure's CPackCommon.
include(CPackCommon)
include(ThirdPartyNotices)
include(OrtPackageVariant)

kataglyphis_cpack_common(
  VENDOR
  "${AUTHOR}"
  PACKAGE_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.png"
  # EGL and the X extension libraries remain host-owned and are used by the media closure.
  DEBIAN_DEPENDS
  "libc6 (>= 2.31), libegl1, libxext6, libxrender1"
  NSIS_WELCOME_TITLE
  "Inference on caffeine boost."
  NSIS_FINISH_TITLE
  "AccelerANTgine is installed."
  NSIS_HEADER_IMAGE
  "${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.bmp"
  NSIS_MUI_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/faviconNew.ico"
  # Never change it or share it: the upgrade code is the MSI identity, and a shared one lets products uninstall each other.
  WIX_UPGRADE_GUID
  "38C420D3-727D-475C-97E4-7406AA16E1F1"
  WIX_PRODUCT_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/faviconNew.ico"
  WIX_DEFAULT
  OFF
  APPIMAGE_DEFAULT
  ON
  # Must match the install() RENAMEs in CMakeLists.txt: the AppImage generator resolves both by name.
  APPIMAGE_DESKTOP_FILE
  "${PROJECT_APP_ID}.desktop"
  APPIMAGE_ICON_NAME
  "${PROJECT_APP_ID}.png"
  # Under /usr the .desktop file and icon land where a desktop looks for them.
  UNIX_INSTALL_PREFIX
  "/usr"
  # NSIS resolves against MAX_PATH, which the full descriptive name overruns in deep workspaces.
  SHORT_WINDOWS_FILE_NAME)

if(WIN32
   AND PROJECT_IS_TOP_LEVEL
   AND NOT
       KATAGLYPHIS_ORT_VARIANT
       STREQUAL
       "cpu")
  # The GPU lane proves finished ZIP and MSI bytes; do not ship an unverified NSIS payload.
  set(CPACK_GENERATOR "ZIP;WIX")
  string(APPEND CPACK_PACKAGE_FILE_NAME "-gpu-${KATAGLYPHIS_ORT_VARIANT}")
endif()

if(WIN32
   AND PROJECT_IS_TOP_LEVEL
   AND KATAGLYPHIS_GST_PLUGIN_DIR)
  install(DIRECTORY "${KATAGLYPHIS_GST_PLUGIN_DIR}/" DESTINATION "${CMAKE_INSTALL_LIBDIR}/gstreamer-1.0")
endif()

# The image's own GStreamer and plugins travel, never the distro's; an embedding project bundles its own (AGENTS.md).
if(UNIX
   AND NOT APPLE
   AND PROJECT_IS_TOP_LEVEL)
  find_package(PkgConfig REQUIRED)
  pkg_get_variable(_gst_plugins_dir gstreamer-1.0 pluginsdir)
  pkg_get_variable(_gst_lib_dir gstreamer-1.0 libdir)
  pkg_get_variable(_ffmpeg_lib_dir libavcodec libdir)
  set(_gst_plugin_dest "${CMAKE_INSTALL_LIBDIR}/accelerantgine/gstreamer-1.0")
  set(_gst_plugins
      coreelements
      app
      videoconvertscale
      videorate
      videofilter
      videotestsrc
      playback
      typefindfunctions
      rawparse
      videoparsersbad
      debugutilsbad
      video4linux2
      libav
      isomp4
      rswebrtc
      rsrtp
      webrtc
      nice
      dtls
      srtp
      sctp
      rtpmanager
      rtp
      vpx)
  foreach(_plugin IN LISTS _gst_plugins)
    set(_file "${_gst_plugins_dir}/libgst${_plugin}.so")
    if(NOT EXISTS "${_file}")
      message(FATAL_ERROR "GStreamer plugin ${_plugin} is not in ${_gst_plugins_dir}")
    endif()
    file(REAL_PATH "${_file}" _real)
    install(
      FILES "${_real}"
      DESTINATION "${_gst_plugin_dest}"
      RENAME "libgst${_plugin}.so")
  endforeach()
  # H.264 is a second codec offer and libcamerasrc serves Pi cameras; both are optional extras.
  foreach(_file "${_gst_plugins_dir}/libgstopenh264.so" "/opt/libcamera/lib/gstreamer-1.0/libgstlibcamera.so")
    if(EXISTS "${_file}")
      file(REAL_PATH "${_file}" _real)
      get_filename_component(_name "${_file}" NAME)
      install(
        FILES "${_real}"
        DESTINATION "${_gst_plugin_dest}"
        RENAME "${_name}")
    endif()
  endforeach()
  # libsrtp2's NSS dlopens its softokn and freebl modules from beside libnss3, which the closure bundles.
  find_library(_nss3 nss3)
  if(_nss3)
    get_filename_component(_nss_dir "${_nss3}" DIRECTORY)
    foreach(_module libsoftokn3.so libfreeblpriv3.so libfreebl3.so)
      if(EXISTS "${_nss_dir}/${_module}")
        file(REAL_PATH "${_nss_dir}/${_module}" _real)
        install(
          FILES "${_real}"
          DESTINATION "${CMAKE_INSTALL_LIBDIR}/accelerantgine"
          RENAME "${_module}")
      endif()
    endforeach()
  endif()
endif()

# The compiler's libstdc++, the chain ORT and the image's glibc: GCC 16.2's and glibc 2.43 are newer than Debian 13's.
get_filename_component(_ort_lib_dir "${_ONNXRUNTIME_LIB}" DIRECTORY)
set(_gpu_closure_args "")
set(_gpu_provider "")
if(PROJECT_IS_TOP_LEVEL
   AND CMAKE_SYSTEM_NAME STREQUAL "Linux"
   AND NOT
       KATAGLYPHIS_ORT_VARIANT
       STREQUAL
       "cpu")
  accelerantgine_require_gpu_packaging_hub("${CMAKE_CURRENT_SOURCE_DIR}/third_party/ANTfrastructure" _gpu_helper)
  if(KATAGLYPHIS_ORT_VARIANT STREQUAL "nvidia")
    set(_gpu_provider libonnxruntime_providers_cuda.so)
    set(_gpu_kind cuda)
  else()
    set(_gpu_provider libonnxruntime_providers_migraphx.so)
    set(_gpu_kind migraphx)
  endif()
  foreach(_required libonnxruntime_providers_shared.so ${_gpu_provider})
    if(NOT EXISTS "${_ort_lib_dir}/${_required}")
      message(FATAL_ERROR "${KATAGLYPHIS_ORT_VARIANT} package requires ${_ort_lib_dir}/${_required}")
    endif()
  endforeach()
  accelerantgine_gpu_host_dependencies(
    "${_gpu_helper}"
    "${_ort_lib_dir}/${_gpu_provider}"
    "${_gpu_kind}"
    _gpu_system)
  install(
    CODE "execute_process(COMMAND bash \"${_gpu_helper}\" \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/accelerantgine\" \"${_ort_lib_dir}\" \"${KATAGLYPHIS_ORT_VARIANT}\" COMMAND_ERROR_IS_FATAL ANY)"
  )
  set(_gpu_closure_args
      EXTERNAL_LIBRARY_PATH
      NO_DEFAULT_SYSTEM
      PRESERVE_ORT_IN_APPIMAGE
      SYSTEM
      ${_gpu_system}
      "libc.so.6"
      "libm.so.6"
      "libpthread.so.0"
      "libdl.so.2"
      "librt.so.1"
      "libresolv.so.2"
      "libutil.so.1"
      "libanl.so.1"
      "libnsl.so.1"
      "ld-linux*.so*"
      "libGL.so.1"
      "libEGL.so.1"
      "libGLX.so.0"
      "libOpenGL.so.0"
      "libX11.so.6"
      "libXext.so.6"
      "libXrender.so.1"
      "libICE.so.6"
      "libSM.so.6")
  string(APPEND CPACK_PACKAGE_FILE_NAME "-gpu-${KATAGLYPHIS_ORT_VARIANT}")
endif()
set(_closure_search
    "${_ort_lib_dir}"
    "${_gst_lib_dir}"
    "${_ffmpeg_lib_dir}"
    "/opt/libcamera/lib"
    "/usr/lib/${CMAKE_LIBRARY_ARCHITECTURE}"
    "/lib/${CMAKE_LIBRARY_ARCHITECTURE}")
kataglyphis_install_linux_closure(
  LOADER
  PRIVATE_DIR
  accelerantgine
  TARGETS
  ${PROJECT_NAME}
  ${PROJECT_NAME}_cli
  ${PROJECT_NAME}_demo
  SEARCH
  ${_closure_search}
  ${_gpu_closure_args}
  PROTECT
  "lib/accelerantgine/libonnxruntime*")
if(PROJECT_IS_TOP_LEVEL AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(_gst_launchers "")
  if(TARGET ${PROJECT_NAME}_cli)
    string(APPEND _gst_launchers " \"$<TARGET_FILE_NAME:${PROJECT_NAME}_cli>\"")
  endif()
  if(TARGET ${PROJECT_NAME}_demo)
    string(APPEND _gst_launchers " \"$<TARGET_FILE_NAME:${PROJECT_NAME}_demo>\"")
  endif()
  if(_gst_launchers)
    install(
      CODE "execute_process(COMMAND bash \"${CMAKE_CURRENT_SOURCE_DIR}/scripts/linux/isolate-package-gstreamer.sh\" \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR}\"${_gst_launchers} COMMAND_ERROR_IS_FATAL ANY)"
    )
  endif()
endif()
if(PROJECT_IS_TOP_LEVEL AND _gpu_provider)
  accelerantgine_install_gpu_host_runtime_guard("${_gpu_helper}" "${_gpu_kind}")
endif()
# A provider is dlopened, so verify its notices against the same wheel as the staged core.
if(PROJECT_IS_TOP_LEVEL AND _gpu_provider)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  if(DEFINED ENV{ORT_CHAIN_WHEEL_DIR})
    set(_gpu_wheels "$ENV{ORT_CHAIN_WHEEL_DIR}")
  else()
    set(_gpu_wheels "/opt/onnxruntime-wheels")
  endif()
  if(CMAKE_STRIP)
    set(_gpu_strip "${CMAKE_STRIP}")
  else()
    set(_gpu_strip strip)
  endif()
  install(
    CODE "set(_pkg \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\")
execute_process(COMMAND \"${Python3_EXECUTABLE}\" \"${CMAKE_CURRENT_SOURCE_DIR}/third_party/ANTfrastructure/linux/scripts/06-packaging/stage-ort-wheel-licenses.py\" --wheel-dir \"${_gpu_wheels}\" --destination \"\${_pkg}/share\" --strip \"${_gpu_strip}\" --library \"\${_pkg}/${CMAKE_INSTALL_LIBDIR}/accelerantgine/libonnxruntime.so.1\" --library \"\${_pkg}/${CMAKE_INSTALL_LIBDIR}/accelerantgine/libonnxruntime_providers_shared.so\" --library \"\${_pkg}/${CMAKE_INSTALL_LIBDIR}/accelerantgine/${_gpu_provider}\" COMMAND_ERROR_IS_FATAL ANY)"
  )
  configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifyGpuAppImage.cmake.in"
                 "${PROJECT_BINARY_DIR}/VerifyGpuAppImage.cmake" @ONLY)
  list(APPEND CPACK_POST_BUILD_SCRIPTS "${PROJECT_BINARY_DIR}/VerifyGpuAppImage.cmake")
endif()
# After the closure: the notices list exactly what each generator is about to pack, in the closure's search order.
accelerantgine_install_linux_notices(SEARCH ${_closure_search})
accelerantgine_install_windows_notices()

include(CPack)
