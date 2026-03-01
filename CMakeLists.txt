cmake_minimum_required(VERSION 3.31.6)

# set the project name
project(
  KataglyphisCppInference
  VERSION 0.0.1
  DESCRIPTION "Lore ipsum"
  HOMEPAGE_URL "https://jonasheinle.de/"
  LANGUAGES CXX C)

include(GNUInstallDirs)

set(AUTHOR "Jonas Heinle")
set(PROJECT_APP_ID "org.kataglyphis.kataglyphiscppinference")

# Set WINDOWS_CI to OFF by default
# WINDOWS CI is only able to verify successful compiling ... Windows ... lel
# i will stay on linux ...
set(WINDOWS_CI
    OFF
    CACHE BOOL "Enable Windows CI build options")
set(RUST_FEATURES
    ON
    CACHE BOOL "Enable Rust features in our project.")

if(RUST_FEATURES)
  message(STATUS "Rust features are enabled.")
  if(MSVC)
    message(STATUS "On a windows machine you must use MSVC or clang-cl when integrating rust features.")
  endif()
else()
  message(STATUS "Rust features are disabled.")
  message(
    STATUS "Your are going to use a non MSVC/clang-cl compiler on windows. Therefore no rust integration possible.")
endif()

include(cmake/PreventInSourceBuilds.cmake)
include(cmake/ProjectOptions.cmake)

myproject_setup_options()

myproject_global_options()

message(STATUS "About to call the local options function.")
myproject_local_options()

include(cmake/SystemLibDependencies.cmake)
if(myproject_ENABLE_SANITIZER_ADDRESS)

  add_compile_options(-fsanitize=address)

  add_link_options(-fsanitize=address)

endif()

if(myproject_ENABLE_COVERAGE AND NOT CMAKE_BUILD_TYPE STREQUAL "Release" AND CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")

  add_compile_options(-fprofile-instr-generate -fcoverage-mapping)

  add_link_options(-fprofile-instr-generate -fcoverage-mapping)

endif()

add_subdirectory(ExternalLib)

if(BUILD_TESTING
   AND NOT WIN32
   AND CMAKE_CXX_COMPILER_ID MATCHES "Clang"
   AND NOT (CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo"))
  # Fuzz flags should be applied on the target, not globally
endif()

add_subdirectory(Src)

if(NOT WINDOWS_CI AND BUILD_TESTING)
  include(CTest)
  enable_testing()
  message(STATUS "WINDOWS_CI is OFF or not defined.")
else()
  message(STATUS "WINDOWS_CI is OFF or not defined.")
endif()

if(BUILD_TESTING)
  message(STATUS "Tests are enabled.!")
  add_subdirectory(Test/commit)
  add_subdirectory(Test/compile)
  add_subdirectory(Test/perf)
  add_subdirectory(Test/fuzz)
else()
  message(STATUS "Tests are disabled.!")
endif()

# for correct library output needed
install(
  TARGETS ${PROJECT_NAME}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(TARGET ${PROJECT_NAME}_cli)
  install(TARGETS ${PROJECT_NAME}_cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

if(UNIX AND NOT APPLE)
  install(
    FILES ${CMAKE_CURRENT_SOURCE_DIR}/resources/packaging/${PROJECT_NAME}.desktop
    DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications
    RENAME ${PROJECT_APP_ID}.desktop)
  install(
    FILES ${CMAKE_CURRENT_SOURCE_DIR}/resources/packaging/${PROJECT_NAME}.appdata.xml
    DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/metainfo
    RENAME ${PROJECT_APP_ID}.appdata.xml)
  install(
    FILES ${CMAKE_CURRENT_SOURCE_DIR}/images/Engine_logo.png
    DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/256x256/apps
    RENAME ${PROJECT_APP_ID}.png)
endif()
# we keep the relative paths in the install dir
# keep in mind that install dir will be in front of this relative path ...

include(cmake/CPackOptions.cmake)
