cmake_minimum_required(VERSION 3.31.6)

# set the project name
project(
  KataglyphisCppInference
  VERSION 0.0.1
  DESCRIPTION "Lore ipsum"
  HOMEPAGE_URL "https://jonasheinle.de/"
  LANGUAGES CXX C)

include(cmake/ClangClModules.cmake)

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
set(MYPROJECT_GCC_TOOLCHAIN_PATH
    ""
    CACHE PATH "Optional GCC toolchain root used by Clang and Rust tooling on Linux (for example /opt/gcc-15.2.0)")

# Auto-detect custom GCC toolchain for Clang on Linux to avoid workflow env setup
if(UNIX
   AND NOT APPLE
   AND MYPROJECT_GCC_TOOLCHAIN_PATH
   AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  set(_GCC_TOOLCHAIN_ROOT "${MYPROJECT_GCC_TOOLCHAIN_PATH}")
  set(_GCC_TOOLCHAIN_LIB "${_GCC_TOOLCHAIN_ROOT}/lib64")
  if(NOT EXISTS "${_GCC_TOOLCHAIN_LIB}")
    set(_GCC_TOOLCHAIN_LIB "${_GCC_TOOLCHAIN_ROOT}/lib")
  endif()

  if(EXISTS "${_GCC_TOOLCHAIN_LIB}")
    message(STATUS "Using GCC toolchain at ${_GCC_TOOLCHAIN_ROOT} for Clang")
    string(APPEND CMAKE_C_FLAGS " --gcc-toolchain=${_GCC_TOOLCHAIN_ROOT}")
    string(APPEND CMAKE_CXX_FLAGS " --gcc-toolchain=${_GCC_TOOLCHAIN_ROOT}")
    string(APPEND CMAKE_EXE_LINKER_FLAGS
           " -L${_GCC_TOOLCHAIN_LIB} -Wl,-rpath,${_GCC_TOOLCHAIN_LIB} --gcc-toolchain=${_GCC_TOOLCHAIN_ROOT}")
    string(APPEND CMAKE_SHARED_LINKER_FLAGS
           " -L${_GCC_TOOLCHAIN_LIB} -Wl,-rpath,${_GCC_TOOLCHAIN_LIB} --gcc-toolchain=${_GCC_TOOLCHAIN_ROOT}")
  else()
    message(WARNING "GCC toolchain found at ${_GCC_TOOLCHAIN_ROOT}, but no lib or lib64 dir exists.")
  endif()
endif()

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

option(KATAGLYPHIS_ENABLE_TIME_TRACE "Enable Clang -ftime-trace for build profiling" OFF)
if(KATAGLYPHIS_ENABLE_TIME_TRACE AND CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
  message(STATUS "=== ENABLING CLANG TIME TRACE PROFILING ===")
  message(STATUS "Look for .json trace files next to the compiled objects.")
  if(MSVC)
    add_compile_options("/clang:-ftime-trace")
  else()
    add_compile_options("-ftime-trace")
  endif()
endif()

message(STATUS "About to call the local options function.")
myproject_local_options()

include(cmake/SystemLibDependencies.cmake)
if(myproject_ENABLE_SANITIZER_ADDRESS)
  if(MSVC)
    # Keep STL annotation settings consistent for all targets (including gtest)
    # to avoid LNK2038 mismatches with AddressSanitizer builds.
    add_compile_definitions(_DISABLE_VECTOR_ANNOTATION _DISABLE_STRING_ANNOTATION)
    if(NOT
       CMAKE_CXX_COMPILER_ID
       STREQUAL
       "Clang")
      add_compile_options(/fsanitize=address /Zi)
      add_link_options(/INCREMENTAL:NO)
    endif()
  else()
    add_compile_options(-fsanitize=address)
    add_link_options(-fsanitize=address)
  endif()

endif()

if(myproject_ENABLE_COVERAGE
   AND NOT
       CMAKE_BUILD_TYPE
       STREQUAL
       "Release"
   AND CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")

  add_compile_options(-fprofile-instr-generate -fcoverage-mapping)

  add_link_options(-fprofile-instr-generate -fcoverage-mapping)

endif()

add_subdirectory(ExternalLib)

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
  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_subdirectory(Test/commit)
    add_subdirectory(Test/compile)
    if(NOT myproject_ENABLE_SANITIZER_THREAD)
      add_subdirectory(Test/fuzz)
      message(STATUS "Building test suites: commit, compile, fuzz (Debug)")
    else()
      message(STATUS "Building test suites: commit, compile (Debug, skipped fuzz due to TSAN)")
    endif()
  elseif(CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    add_subdirectory(Test/perf)
    message(STATUS "Building test suite: perf (RelWithDebInfo)")
  else()
    message(
      STATUS
        "Skipping test suites for CMAKE_BUILD_TYPE='${CMAKE_BUILD_TYPE}'. Use Debug for commit/compile/fuzz or RelWithDebInfo for perf."
    )
  endif()
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
