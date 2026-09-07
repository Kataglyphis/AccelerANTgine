cmake_minimum_required(VERSION 3.31.6)

# set the project name
project(
  AccelerANTgine
  VERSION 0.0.1
  DESCRIPTION "C++23 ONNX inference engine with GStreamer and WebRTC support"
  HOMEPAGE_URL "https://jonasheinle.de/"
  LANGUAGES CXX C)

include(GNUInstallDirs)

set(AUTHOR "Jonas Heinle")
set(PROJECT_APP_ID "org.kataglyphis.accelerantgine")

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

option(KATAGLYPHIS_BUILD_PYTHON_BINDINGS "Build Python bindings with nanobind" OFF)
if(KATAGLYPHIS_BUILD_PYTHON_BINDINGS)
  # nanobind requires C++ exceptions in the binding TU, and module BMIs re-emit
  # exception flags into every importer — keep the whole project consistent.
  set(myproject_DISABLE_EXCEPTIONS
      OFF
      CACHE BOOL "Disable C++ exceptions (forced OFF: Python bindings need them)" FORCE)
endif()

# Reusable CMake modules live upstream in the ContainerHub submodule so every
# consumer gets the same ones (AGENTS.md section 2, "CMake modules:
# ContainerHub-first, local override wins"); this repo's own cmake/ keeps only
# what encodes THIS project's choices.
# Both dirs go on CMAKE_MODULE_PATH so every module is included by NAME -
# `include(Sanitizers)`, not `include(cmake/Sanitizers.cmake)` - which is what
# lets a module live in either directory without its callers caring.
#
# Local first: a project that needs to override an upstream module drops a
# same-named file in cmake/ and wins, without editing ContainerHub. No local
# override remains today: Cache, Tests, Sanitizers and StaticAnalyzers were all
# reconciled upstream 2026-09-06 and their local copies are gone.
set(KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ContainerHub/cmake")
# Probe CompilerWarnings.cmake, not just the directory: it is one of the modules
# this repo now has NO local copy of, so its absence is exactly the failure an
# uninitialised submodule causes - a confusing "Could not find a module" from
# deep inside ProjectOptions instead of a message naming the real cause.
if(NOT EXISTS "${KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR}/CompilerWarnings.cmake")
  message(
    FATAL_ERROR "ContainerHub submodule not checked out: ${KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR} has no CMake modules. "
                "Run: git submodule update --init --recursive")
endif()
list(
  APPEND
  CMAKE_MODULE_PATH
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake"
  "${KATAGLYPHIS_CONTAINERHUB_CMAKE_DIR}")

include(PreventInSourceBuilds)
include(ProjectOptions)

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

include(SystemLibDependencies)
if(myproject_ENABLE_SANITIZER_ADDRESS)
  if(MSVC)
    add_compile_definitions(
      _DISABLE_VECTOR_ANNOTATION
      _DISABLE_STRING_ANNOTATION
      _DISABLE_OPTIONAL_ANNOTATION
      _ITERATOR_DEBUG_LEVEL=0)
    if(NOT
       CMAKE_CXX_COMPILER_ID
       STREQUAL
       "Clang")
      add_compile_options(/fsanitize=address /Zi)
      add_link_options(/INCREMENTAL:NO)
    endif()
    # clang-cl: Sanitizers.cmake links clang_rt.asan_dynamic, which supports the
    # dynamic CRT — keep CMAKE_MSVC_RUNTIME_LIBRARY as passed in (MultiThreadedDLL
    # when embedding in Flutter). Forcing the static CRT here poisons every object
    # with /MT vs /MD failifmismatch records.
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

  if(MSVC)
    # clang-cl on Windows: -fprofile-instr-generate/-fcoverage-mapping are not
    # understood by lld-link.  Use /clang: prefix for compile flags and link the
    # profile runtime explicitly.
    add_compile_options(/clang:-fprofile-instr-generate /clang:-fcoverage-mapping)
    execute_process(
      COMMAND ${CMAKE_CXX_COMPILER} --print-resource-dir
      RESULT_VARIABLE _GLOBAL_RESOURCE_DIR_RC
      OUTPUT_VARIABLE _GLOBAL_CLANG_RESOURCE_DIR
      OUTPUT_STRIP_TRAILING_WHITESPACE)
    # A build explicitly asked for coverage must instrument or fail loud here -
    # a WARNING-and-continue silently produced uninstrumented "coverage" builds.
    if(NOT
       _GLOBAL_RESOURCE_DIR_RC
       EQUAL
       0
       OR "${_GLOBAL_CLANG_RESOURCE_DIR}" STREQUAL "")
      message(FATAL_ERROR "Coverage was requested, but '${CMAKE_CXX_COMPILER} --print-resource-dir' failed "
                          "(exit ${_GLOBAL_RESOURCE_DIR_RC}); cannot locate the clang profile runtime to link.")
    endif()
    set(_GLOBAL_RUNTIME_DIR "${_GLOBAL_CLANG_RESOURCE_DIR}/lib/windows")
    set(_GLOBAL_PROFILE_LIB "${_GLOBAL_RUNTIME_DIR}/clang_rt.profile-x86_64.lib")
    if(NOT EXISTS "${_GLOBAL_PROFILE_LIB}")
      message(FATAL_ERROR "Coverage was requested, but the clang-cl profile runtime is missing: "
                          "${_GLOBAL_PROFILE_LIB}")
    endif()
    add_link_options("/LIBPATH:${_GLOBAL_RUNTIME_DIR}")
    link_libraries(clang_rt.profile-x86_64)
  else()
    add_compile_options(-fprofile-instr-generate -fcoverage-mapping)
    add_link_options(-fprofile-instr-generate -fcoverage-mapping)
  endif()

endif()

if(KATAGLYPHIS_BUILD_PYTHON_BINDINGS)
  find_package(Python 3.12 REQUIRED COMPONENTS Interpreter Development.Module)
endif()

add_subdirectory(third_party)

add_subdirectory(Src)

if(KATAGLYPHIS_BUILD_PYTHON_BINDINGS)
  add_subdirectory(Bindings/python)
endif()

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

include(CPackOptions)
