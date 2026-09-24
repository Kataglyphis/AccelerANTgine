# One MSVC runtime for the whole build.
#
# A dependency can pin its own CMAKE_MSVC_RUNTIME_LIBRARY in its directory scope:
# abseil 20260526.0 sets "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" (its
# CMakeLists.txt:64-67). Under the clang-cl ASAN Debug preset, where
# ProjectOptions forces MultiThreadedDLL (clang_rt.asan_dynamic needs the release
# CRT), every absl object then carried MDd, and the first link that mixed them
# (FUZZTEST's grammar_domain_code_generator) died on lld-link /failifmismatch
# 'RuntimeLibrary' after nine minutes of compiling. These helpers re-point such
# targets, and fail the configure when anything would still link another runtime.

# The runtime a value selects for this (single-config) build, so that
# "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" and "MultiThreadedDebugDLL" compare equal.
function(myproject_resolve_msvc_runtime value out_var)
  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_debug "Debug")
  else()
    set(_debug "")
  endif()
  string(
    REPLACE "$<$<CONFIG:Debug>:Debug>"
            "${_debug}"
            _resolved
            "${value}")
  set(${out_var}
      "${_resolved}"
      PARENT_SCOPE)
endfunction()

# Every target under <dir> (recursively) that compiles, and so records a RuntimeLibrary.
function(myproject_collect_compiled_targets dir out_var)
  set(_found "")
  get_property(
    _targets
    DIRECTORY "${dir}"
    PROPERTY BUILDSYSTEM_TARGETS)
  foreach(_target IN LISTS _targets)
    get_target_property(_type "${_target}" TYPE)
    if(_type MATCHES "^(STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY|OBJECT_LIBRARY|EXECUTABLE)$")
      list(APPEND _found "${_target}")
    endif()
  endforeach()
  get_property(
    _subdirs
    DIRECTORY "${dir}"
    PROPERTY SUBDIRECTORIES)
  foreach(_subdir IN LISTS _subdirs)
    myproject_collect_compiled_targets("${_subdir}" _sub_found)
    list(APPEND _found ${_sub_found})
  endforeach()
  set(${out_var}
      "${_found}"
      PARENT_SCOPE)
endfunction()

# Pin every compiled target under <dir> to the project's CMAKE_MSVC_RUNTIME_LIBRARY.
function(myproject_force_msvc_runtime dir)
  if(NOT MSVC OR NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
    return()
  endif()
  myproject_collect_compiled_targets("${dir}" _targets)
  foreach(_target IN LISTS _targets)
    set_property(TARGET "${_target}" PROPERTY MSVC_RUNTIME_LIBRARY "${CMAKE_MSVC_RUNTIME_LIBRARY}")
  endforeach()
endfunction()

# FATAL_ERROR naming every compiled target under <dir> that would link another runtime.
function(myproject_check_msvc_runtime dir)
  if(NOT MSVC OR NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
    return()
  endif()
  myproject_resolve_msvc_runtime("${CMAKE_MSVC_RUNTIME_LIBRARY}" _want)
  myproject_collect_compiled_targets("${dir}" _targets)
  set(_bad "")
  foreach(_target IN LISTS _targets)
    get_target_property(_runtime "${_target}" MSVC_RUNTIME_LIBRARY)
    if(NOT _runtime)
      # Unset means CMake's default, which is the DEBUG CRT in a Debug build.
      set(_runtime "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
    endif()
    myproject_resolve_msvc_runtime("${_runtime}" _have)
    if(NOT
       "${_have}"
       STREQUAL
       "${_want}")
      list(APPEND _bad "${_target} (${_have})")
    endif()
  endforeach()
  if(_bad)
    list(
      JOIN
      _bad
      "\n  "
      _bad_text)
    message(
      FATAL_ERROR
        "These targets would link another MSVC runtime than ${_want}, and lld-link would stop on "
        "/failifmismatch 'RuntimeLibrary':\n  ${_bad_text}\n"
        "Pin them with myproject_force_msvc_runtime() (cmake/MsvcRuntime.cmake).")
  endif()
endfunction()
