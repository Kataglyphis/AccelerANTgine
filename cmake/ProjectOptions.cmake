# This project's build POLICY: which options exist, what they default to, and
# how the reusable modules are composed.
#
# The shared mechanism - the core option list and the per-target dispatch that
# this file and BeschleunigerBallett/cmake/ProjectOptions.cmake had drifted into
# near-copies of - was hoisted to ContainerHub on 2026-09-09 as
# ProjectOptionsCommon and is included by name off CMAKE_MODULE_PATH (see the
# top of the root CMakeLists.txt).
#
# What stays here is what another project would NOT want copied: the sanitizer
# default policy (Debug-only UBSan, the ThreadSanitizer override), exceptions
# behind myproject_DISABLE_EXCEPTIONS because the Python bindings need them,
# C++23, C++ modules mandatory, and this project's build-type gating - static
# analysis only in Debug, sanitizers and IWYU only outside Release.

include(CMakeDependentOption)
include(CheckCXXCompilerFlag)

include(ProjectOptionsCommon)

# include() above already fails hard when the module is not on CMAKE_MODULE_PATH.
# This catches the other, quieter failure: a STALE same-named file in this repo's
# own cmake/ directory, which is first on CMAKE_MODULE_PATH and would therefore
# win - loading fine and then leaving every macro below undefined.
if(NOT COMMAND myproject_define_core_options
   OR NOT DEFINED MYPROJECT_PROJECT_OPTIONS_COMMON_VERSION
   OR MYPROJECT_PROJECT_OPTIONS_COMMON_VERSION LESS 1)
  message(FATAL_ERROR "ProjectOptionsCommon resolved to a file that does not provide "
                      "myproject_define_core_options (version >= 1). CMAKE_MODULE_PATH is: ${CMAKE_MODULE_PATH}")
endif()

# Deliberately NOT ContainerHub's SanitizerSupport::myproject_supports_sanitizers:
# that one carries a GCC-15 UBSan carve-out and a different ASan matrix. Adopting
# it would change this project's Debug sanitizer defaults, which is a separate
# decision from hoisting the option list.
macro(myproject_supports_sanitizers)
  if((CMAKE_CXX_COMPILER_ID MATCHES ".*Clang.*" OR CMAKE_CXX_COMPILER_ID MATCHES ".*GNU.*") AND NOT WIN32)
    set(SUPPORTS_UBSAN ON)
  else()
    set(SUPPORTS_UBSAN OFF)
  endif()

  if((CMAKE_CXX_COMPILER_ID MATCHES ".*Clang.*" OR CMAKE_CXX_COMPILER_ID MATCHES ".*GNU.*") AND WIN32)
    set(SUPPORTS_ASAN OFF)
  else()
    set(SUPPORTS_ASAN ON)
  endif()
endmacro()

macro(myproject_setup_options)
  option(myproject_ENABLE_HARDENING "Enable hardening" OFF)
  option(myproject_ENABLE_COVERAGE "Enable coverage reporting" OFF)
  option(myproject_DISABLE_EXCEPTIONS "Disable C++ exceptions" ON)
  option(myproject_ENABLE_GPROF "Enable profiling with gprof (adds -pg flags)" OFF)
  # for now disable global hardening, as it is not supported by all dependencies
  option(myproject_ENABLE_GLOBAL_HARDENING "Enable global hardening for all dependencies" OFF)
  if(myproject_ENABLE_GLOBAL_HARDENING)
    message(WARNING "Global hardening is enabled, but it is not supported by all dependencies.")
  else()
    message(STATUS "Global hardening is disabled")
  endif()

  # namely FUZZTEST
  # cmake_dependent_option(
  #   myproject_ENABLE_GLOBAL_HARDENING
  #   "Attempt to push hardening options to built dependencies"
  #   OFF
  #   myproject_ENABLE_HARDENING
  #   OFF)

  myproject_supports_sanitizers()

  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
      set(DEFAULT_ASAN ON)
    elseif(MSVC AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"))
      # MSVC debug: enable AddressSanitizer by default.
      set(DEFAULT_ASAN ON)
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
      # clang-cl debug: enable AddressSanitizer by default.
      set(DEFAULT_ASAN ON)
    else()
      set(DEFAULT_ASAN OFF)
    endif()
  else()
    set(DEFAULT_ASAN OFF)
  endif()

  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND SUPPORTS_UBSAN)
      set(DEFAULT_UBSAN ON)
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
      # clang-cl debug: enable UBSan by default.
      set(DEFAULT_UBSAN ON)
    else()
      set(DEFAULT_UBSAN OFF)
    endif()
  else()
    set(DEFAULT_UBSAN OFF)
  endif()

  # Thread sanitizer option overrides ASan and UBSan
  option(USE_THREAD_SANITIZER "Use ThreadSanitizer instead of Address/UndefinedBehavior Sanitizer" OFF)
  if(USE_THREAD_SANITIZER)
    set(DEFAULT_ASAN OFF)
    set(DEFAULT_UBSAN OFF)
    set(DEFAULT_TSAN ON)
  else()
    set(DEFAULT_TSAN OFF)
  endif()

  # cppcheck OFF is this project's own call; BeschleunigerBallett keeps it ON.
  myproject_define_core_options(
    ASAN_DEFAULT
    ${DEFAULT_ASAN}
    UBSAN_DEFAULT
    ${DEFAULT_UBSAN}
    TSAN_DEFAULT
    ${DEFAULT_TSAN}
    CPPCHECK_DEFAULT
    OFF)

  if(NOT
     CMAKE_BUILD_TYPE
     STREQUAL
     "Debug")
    if(myproject_ENABLE_SANITIZER_UNDEFINED)
      message(STATUS "Disabling UBSan: this project enables it only for Debug builds.")
    endif()
    set(myproject_ENABLE_SANITIZER_UNDEFINED
        OFF
        CACHE BOOL "Enable undefined sanitizer" FORCE)
  endif()

  myproject_mark_core_options_advanced(myproject_DISABLE_EXCEPTIONS)

endmacro()

macro(myproject_global_options)

  # specify the C/C++ standard
  set(CMAKE_CXX_STANDARD 23)
  set(CMAKE_CXX_STANDARD_REQUIRED True)

  set(CMAKE_C_STANDARD 17)
  set(CMAKE_C_STANDARD_REQUIRED True)

  # C++ modules configuration (mirrors BeschleunigerBallett)
  set(myproject_CXX_SCAN_FOR_MODULES ON)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
    set(myproject_CXX_SCAN_FOR_MODULES OFF)
    message(
      STATUS "Disabling C++ module scanning for clang-cl to avoid CMake generate-time dependency scanner failures.")
  endif()

  set(CMAKE_CXX_SCAN_FOR_MODULES ${myproject_CXX_SCAN_FOR_MODULES})
  set(MYPROJECT_CXX_SCAN_FOR_MODULES
      ${myproject_CXX_SCAN_FOR_MODULES}
      CACHE INTERNAL "Global C++ module scan switch for project targets")

  myproject_cpp_modules_supported()

  # Policy, not mechanism: this project has no header-based fallback, so an
  # unsupported toolchain is a hard stop rather than a degraded build.
  if(NOT myproject_CPP_MODULES_SUPPORTED)
    message(
      FATAL_ERROR
        "This project is configured for C++ modules. Use a module-capable toolchain (Clang >= 17, GCC >= 14, or MSVC >= 19.34 with CMake >= 3.28)."
    )
  endif()

  set(myproject_USE_CPP_MODULES ON)
  set(MYPROJECT_USE_CPP_MODULES
      ${myproject_USE_CPP_MODULES}
      CACHE INTERNAL "Global C++ modules enable switch")
  message(STATUS "C++ modules are enabled for compiler '${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}'.")

  # set build type specific flags
  if(MSVC AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"))
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /DEBUG /Od /std:c++23preview")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /O2 /GL /std:c++23preview")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} /O2 /std:c++23preview")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    # https://gcc.gnu.org/onlinedocs/gcc/Debugging-Options.html
    # https://gcc.gnu.org/onlinedocs/gcc/Option-Summary.html
    set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -ggdb")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} -O3 -DNDEBUG")
    # https://clang.llvm.org/docs/UsersManual.html
    # this is the clang-cl case
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
    # clang-cl accepts -W... style options. These prevent unknown -W... options
    # (or their escalation to errors) from breaking the build when deps inject GCC-only flags.
    set(_CLANG_CL_SAFE_WARNINGS
        "-fcolor-diagnostics -Wno-error=unused-command-line-argument -Wno-error=character-conversion -Wno-unknown-warning-option -Wno-error=unknown-warning-option"
    )
    # Apply to both C and C++ flags (some deps add to C flags)
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /Od ${_CLANG_CL_SAFE_WARNINGS}")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /O2 -DNDEBUG ${_CLANG_CL_SAFE_WARNINGS}")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} /O2 -DNDEBUG ${_CLANG_CL_SAFE_WARNINGS}")
    # https://clang.llvm.org/docs/ClangCommandLineReference.html
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O0 -g -ggdb -fcolor-diagnostics") # -std=c++2a
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG -fcolor-diagnostics")
    set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} -O3 -DNDEBUG -fcolor-diagnostics"
    )# -std=c++2a
  endif()

  myproject_set_output_directories()

  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
     AND MSVC
     AND CMAKE_BUILD_TYPE STREQUAL "Debug"
     AND myproject_ENABLE_SANITIZER_ADDRESS)
    set(CMAKE_MSVC_RUNTIME_LIBRARY
        "MultiThreadedDLL"
        CACHE STRING "MSVC runtime library" FORCE)
  elseif(
    (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
     AND MSVC
     AND myproject_ENABLE_SANITIZER_ADDRESS)
    OR (MSVC
        AND NOT
            CMAKE_CXX_COMPILER_ID
            STREQUAL
            "Clang"
        AND CMAKE_BUILD_TYPE STREQUAL "Debug"
       ))
    set(CMAKE_MSVC_RUNTIME_LIBRARY
        "MultiThreadedDLL"
        CACHE STRING "MSVC runtime library" FORCE)
  elseif(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(CMAKE_MSVC_RUNTIME_LIBRARY
        "MultiThreadedDebugDLL"
        CACHE STRING "MSVC runtime library" FORCE)
  endif()

  myproject_configure_lwyu_and_ipo()

  myproject_supports_sanitizers()

  if(myproject_ENABLE_HARDENING AND myproject_ENABLE_GLOBAL_HARDENING)
    include(Hardening)
    if(NOT SUPPORTS_UBSAN
       OR myproject_ENABLE_SANITIZER_UNDEFINED
       OR myproject_ENABLE_SANITIZER_ADDRESS
       OR myproject_ENABLE_SANITIZER_THREAD
       OR myproject_ENABLE_SANITIZER_LEAK
       OR CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64")
      set(ENABLE_UBSAN_MINIMAL_RUNTIME FALSE)
    else()
      set(ENABLE_UBSAN_MINIMAL_RUNTIME FALSE)
    endif()
    message("${myproject_ENABLE_HARDENING} ${ENABLE_UBSAN_MINIMAL_RUNTIME} ${myproject_ENABLE_SANITIZER_UNDEFINED}")
    myproject_enable_hardening(myproject_options ON ${ENABLE_UBSAN_MINIMAL_RUNTIME})
  endif()
endmacro()

macro(myproject_local_options)
  myproject_create_option_targets()

  myproject_enable_profiling(myproject_options)

  if(myproject_DISABLE_EXCEPTIONS)
    if(MSVC AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"))
      target_compile_options(myproject_options INTERFACE /EHs-) # Disable exceptions
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
      message(STATUS "Using clang-cl and disable exceptions with /GX-")
      target_compile_options(myproject_options INTERFACE /EHs-) # Disable exceptions
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
      target_compile_options(myproject_options INTERFACE -fno-exceptions)
    else()
      message(WARNING "Disabling exceptions is not supported for this compiler.")
    endif()
  else()
    if(MSVC AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang"))
      target_compile_options(myproject_options INTERFACE /EHs) # Enable exceptions
    elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
      target_compile_options(myproject_options INTERFACE /EHs) # Enable exceptions
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
      target_compile_options(myproject_options INTERFACE -fexceptions)
    else()
      message(WARNING "Enabling exceptions is not supported for this compiler.")
    endif()
  endif()

  if(NOT
     CMAKE_BUILD_TYPE
     STREQUAL
     "Release")
    myproject_apply_sanitizers(myproject_options)
  endif()

  myproject_apply_unity_pch_cache(myproject_options)

  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    # Src/.* scopes build-gate clang-tidy to this repo's sources (the retired local
    # StaticAnalyzers override hard-coded it; upstream now takes it as an argument).
    myproject_apply_static_analysis(myproject_options "Src/.*")
  endif()

  myproject_apply_warnings_as_errors_linker_check()

  if(myproject_ENABLE_HARDENING AND NOT myproject_ENABLE_GLOBAL_HARDENING)
    include(Hardening)
    if(NOT SUPPORTS_UBSAN
       OR myproject_ENABLE_SANITIZER_UNDEFINED
       OR myproject_ENABLE_SANITIZER_ADDRESS
       OR myproject_ENABLE_SANITIZER_THREAD
       OR myproject_ENABLE_SANITIZER_LEAK
       OR CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64")
      set(ENABLE_UBSAN_MINIMAL_RUNTIME FALSE)
    else()
      set(ENABLE_UBSAN_MINIMAL_RUNTIME FALSE)
    endif()
    myproject_enable_hardening(myproject_options OFF ${ENABLE_UBSAN_MINIMAL_RUNTIME})
  endif()

  if(NOT
     CMAKE_BUILD_TYPE
     STREQUAL
     "Release")
    myproject_apply_iwyu(myproject_options)

    include(Doxygen)
    enable_doxygen()

    myproject_apply_static_analyzer_flags(myproject_options)
  endif()

  include(Speedup)

endmacro()
