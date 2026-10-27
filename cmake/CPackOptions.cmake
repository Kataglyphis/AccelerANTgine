# Only this project's identity; the CPack wiring is ANTfrastructure's CPackCommon.
include(CPackCommon)
include(ThirdPartyNotices)

kataglyphis_cpack_common(
  VENDOR
  "${AUTHOR}"
  PACKAGE_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.png"
  # glibc and GStreamer travel; EGL is the host's, and the arm64 libcamera plugin links it.
  DEBIAN_DEPENDS
  "libc6 (>= 2.31), libegl1"
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
  SEARCH
  ${_closure_search}
  PROTECT
  "lib/accelerantgine/libonnxruntime*")
# After the closure: the notices list exactly what each generator is about to pack, in the closure's search order.
accelerantgine_install_linux_notices(SEARCH ${_closure_search})
accelerantgine_install_windows_notices()

include(CPack)
