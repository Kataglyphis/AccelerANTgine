# Packaging metadata for THIS project. The wiring it feeds - generator
# selection per platform, the architecture-normalised package name, the NSIS,
# WiX, DEB and AppImage blocks - lives in ANTfrastructure's CPackCommon module,
# because this file was a copy of BeschleunigerBallett's with no shared
# ancestry and the two copies had already drifted.
#
# Everything below is a value that identifies AccelerANTgine and nothing else:
# its icons, its installer copy, its MSI upgrade code, the .desktop file it
# installs. Add project-specific CPACK_* after the call and before include(CPack)
# if this project ever needs one the module does not model.
include(CPackCommon)

kataglyphis_cpack_common(
  VENDOR
  "${AUTHOR}"
  PACKAGE_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.png"
  NSIS_WELCOME_TITLE
  "Get ready for epic graphics."
  NSIS_FINISH_TITLE
  "Now you are ready to render :)"
  NSIS_HEADER_IMAGE
  "${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.bmp"
  NSIS_MUI_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/faviconNew.ico"
  # STABLE FROM HERE ON, and deliberately NOT BeschleunigerBallett's.
  #
  # Until now this file carried BB's literal upgrade code, inherited when it was
  # seeded by copying BB's. An MSI upgrade code is the product's identity to the
  # Windows Installer, so the two shipped as the same product: installing
  # AccelerANTgine over an installed GraphicsEngine would have REMOVED it, and
  # vice versa. That is not theoretical here - WiX defaults OFF below, but
  # scripts/windows/Build-Windows.ps1 passes -DENABLE_WIX_PACKAGING=ON and
  # windows_run.yml uploads the resulting *.msi, so released AccelerANTgine
  # MSIs do carry BB's code.
  #
  # The migration cost is one-way and accepted: an AccelerANTgine already
  # installed under the old code is invisible to an MSI built with this one, so
  # it has to be uninstalled by hand once. The alternative - keeping the
  # collision - leaves two products able to silently uninstall each other,
  # forever.
  WIX_UPGRADE_GUID
  "38C420D3-727D-475C-97E4-7406AA16E1F1"
  WIX_PRODUCT_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/images/faviconNew.ico"
  WIX_DEFAULT
  OFF
  APPIMAGE_DEFAULT
  ON
  # Must match the RENAME in the install() rules in CMakeLists.txt: the
  # AppImage generator resolves both by name, not by path.
  APPIMAGE_DESKTOP_FILE
  "${PROJECT_APP_ID}.desktop"
  APPIMAGE_ICON_NAME
  "${PROJECT_APP_ID}.png"
  # DEB and AppImage payloads have to land under /usr for the .desktop file and
  # the icon to be where a desktop looks for them.
  UNIX_INSTALL_PREFIX
  "/usr"
  # Keep Windows package paths short enough for NSIS in deep workspace trees:
  # the fully descriptive name additionally carries CMAKE_SYSTEM_NAME and the
  # compiler id and version, and NSIS resolves against MAX_PATH.
  SHORT_WINDOWS_FILE_NAME)

include(CPack)
