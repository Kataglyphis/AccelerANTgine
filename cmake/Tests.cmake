function(myproject_enable_coverage project_name)
  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      message(" -- ** Enabling coverage reporting**")
      target_compile_options(${project_name} INTERFACE --coverage)
      target_link_libraries(${project_name} INTERFACE --coverage)
    elseif(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
      message(" -- ** Enabling coverage reporting**")
      if(MSVC)
        # clang-cl on Windows: -fprofile-instr-generate/-fcoverage-mapping are
        # compiler-driver flags; lld-link does not understand them.  Compile
        # flags use the /clang: prefix, and the profile runtime must be linked
        # explicitly.
        target_compile_options(${project_name} INTERFACE /clang:-fprofile-instr-generate
                                                         /clang:-fcoverage-mapping)
        execute_process(
          COMMAND ${CMAKE_CXX_COMPILER} --print-resource-dir
          OUTPUT_VARIABLE _COV_CLANG_RESOURCE_DIR
          OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        if(_COV_CLANG_RESOURCE_DIR)
          set(_COV_RUNTIME_DIR "${_COV_CLANG_RESOURCE_DIR}/lib/windows")
          set(_COV_PROFILE_LIB "${_COV_RUNTIME_DIR}/clang_rt.profile-x86_64.lib")
          if(EXISTS "${_COV_PROFILE_LIB}")
            target_link_directories(${project_name} INTERFACE "${_COV_RUNTIME_DIR}")
            target_link_libraries(${project_name} INTERFACE clang_rt.profile-x86_64)
          else()
            message(WARNING "clang-cl profile runtime not found at ${_COV_PROFILE_LIB}")
          endif()
        else()
          message(WARNING "Unable to detect clang resource directory for coverage runtime linkage")
        endif()
      else()
        target_compile_options(${project_name} INTERFACE -fprofile-instr-generate -fcoverage-mapping)
        target_link_options(${project_name} INTERFACE -fprofile-instr-generate -fcoverage-mapping)
      endif()
    endif()
  else()
    message("Coverage is only enabled for Debug builds.")
  endif()
endfunction()
