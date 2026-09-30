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
  # NSIS resolves against MAX_PATH, which the full descriptive name overruns in deep workspaces.
  SHORT_WINDOWS_FILE_NAME)

include(CPack)
