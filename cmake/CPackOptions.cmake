# Only this project's identity; the CPack wiring is ANTfrastructure's CPackCommon.
include(CPackCommon)

kataglyphis_cpack_common(
  VENDOR
  "${AUTHOR}"
  PACKAGE_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.png"
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
  # glibc travels (LOADER below), GStreamer is the distro's: 1.26 is Debian 13's, measured 2026-10-17.
  DEBIAN_DEPENDS
  "libgstreamer1.0-0 (>= 1.26), libgstreamer-plugins-base1.0-0 (>= 1.26), libgstreamer-plugins-bad1.0-0 (>= 1.26)"
  # NSIS resolves against MAX_PATH, which the full descriptive name overruns in deep workspaces.
  SHORT_WINDOWS_FILE_NAME)

# The compiler's libstdc++, the chain ORT and the image's glibc: GCC 16.2's and glibc 2.43 are newer than Debian 13's.
get_filename_component(_ort_lib_dir "${_ONNXRUNTIME_LIB}" DIRECTORY)
kataglyphis_install_linux_closure(
  LOADER
  PRIVATE_DIR
  accelerantgine
  TARGETS
  ${PROJECT_NAME}
  ${PROJECT_NAME}_cli
  SEARCH
  "${_ort_lib_dir}"
  SYSTEM
  "libgst*-1.0.so.0"
  PROTECT
  "lib/accelerantgine/libonnxruntime*")

include(CPack)
