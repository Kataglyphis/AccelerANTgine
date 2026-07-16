function(
  myproject_enable_sanitizers
  project_name
  ENABLE_SANITIZER_ADDRESS
  ENABLE_SANITIZER_LEAK
  ENABLE_SANITIZER_UNDEFINED_BEHAVIOR
  ENABLE_SANITIZER_THREAD
  ENABLE_SANITIZER_MEMORY)

  set(SANITIZERS "")

  if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
    if(${ENABLE_SANITIZER_ADDRESS})
      list(APPEND SANITIZERS "address")
    endif()

    if(${ENABLE_SANITIZER_LEAK})
      list(APPEND SANITIZERS "leak")
    endif()

    if(${ENABLE_SANITIZER_UNDEFINED_BEHAVIOR})
      list(APPEND SANITIZERS "undefined")
    endif()

    if(${ENABLE_SANITIZER_THREAD})
      if("address" IN_LIST SANITIZERS OR "leak" IN_LIST SANITIZERS)
        message(WARNING "Thread sanitizer does not work with Address and Leak sanitizer enabled")
      else()
        list(APPEND SANITIZERS "thread")
      endif()
    endif()

    if(${ENABLE_SANITIZER_MEMORY} AND CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
      message(
        WARNING
          "Memory sanitizer requires all the code (including libc++) to be MSan-instrumented otherwise it reports false positives"
      )
      if("address" IN_LIST SANITIZERS
         OR "thread" IN_LIST SANITIZERS
         OR "leak" IN_LIST SANITIZERS)
        message(WARNING "Memory sanitizer does not work with Address, Thread or Leak sanitizer enabled")
      else()
        list(APPEND SANITIZERS "memory")
      endif()
    endif()
  elseif(MSVC)
    if(${ENABLE_SANITIZER_ADDRESS})
      list(APPEND SANITIZERS "address")
    endif()
    if(${ENABLE_SANITIZER_LEAK}
       OR ${ENABLE_SANITIZER_UNDEFINED_BEHAVIOR}
       OR ${ENABLE_SANITIZER_THREAD}
       OR ${ENABLE_SANITIZER_MEMORY})
      message(WARNING "MSVC only supports address sanitizer")
    endif()
  endif()

  list(
    JOIN
    SANITIZERS
    ","
    LIST_OF_SANITIZERS)

  if(LIST_OF_SANITIZERS)
    if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang" AND MSVC)
      set(_CLANGCL_COMPILE_SAN_FLAGS "")

      # Detect clang resource directory early; needed for explicit runtime linking
      # because lld-link does not understand -fsanitize= flags.
      execute_process(
        COMMAND ${CMAKE_CXX_COMPILER} --print-resource-dir
        OUTPUT_VARIABLE _CLANG_RESOURCE_DIR
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
      if(_CLANG_RESOURCE_DIR)
        set(_CLANG_RUNTIME_DIR "${_CLANG_RESOURCE_DIR}/lib/windows")
      endif()

      if("address" IN_LIST SANITIZERS)
        # -shared-libsan: make the compiler emit dynamic-ASAN link directives
        # (matching the dynamic CRT /MD). Without it clang-cl defaults to the
        # STATIC ASan runtime and stamps MT_StaticRelease failifmismatch records
        # into every object, which conflicts with /MD builds (Flutter).
        list(APPEND _CLANGCL_COMPILE_SAN_FLAGS /fsanitize=address
             /clang:-shared-libsan)
      endif()

      if("undefined" IN_LIST SANITIZERS)
        list(APPEND _CLANGCL_COMPILE_SAN_FLAGS -fsanitize=undefined)
        # When ASan is also enabled, its (dynamic-CRT) runtime provides the
        # UBSan handlers and prints rich reports. WITHOUT ASan there is no
        # dynamic-CRT UBSan runtime on Windows (clang_rt.ubsan_standalone is
        # built /MT and failifmismatch-es against /MD builds), so use TRAP
        # mode: no runtime needed, undefined behavior raises an immediate
        # debugger break / fast-fail at the offending instruction.
        if(NOT "address" IN_LIST SANITIZERS)
          list(APPEND _CLANGCL_COMPILE_SAN_FLAGS -fsanitize-trap=undefined)
        endif()
      endif()

      if("thread" IN_LIST SANITIZERS)
        message(
          WARNING
            "clang-cl ThreadSanitizer is not supported for target x86_64-pc-windows-msvc; ignoring thread sanitizer request"
        )
      endif()

      if("leak" IN_LIST SANITIZERS OR "memory" IN_LIST SANITIZERS)
        message(
          WARNING
            "clang-cl with MSVC ABI currently supports AddressSanitizer and UndefinedBehaviorSanitizer in this configuration"
        )
      endif()

      if(_CLANGCL_COMPILE_SAN_FLAGS)
        target_compile_options(${project_name} INTERFACE ${_CLANGCL_COMPILE_SAN_FLAGS} /Zi)
        target_link_options(${project_name} INTERFACE /INCREMENTAL:NO)
      endif()

      if("address" IN_LIST SANITIZERS)
        target_compile_definitions(${project_name} INTERFACE _DISABLE_VECTOR_ANNOTATION _DISABLE_STRING_ANNOTATION _DISABLE_OPTIONAL_ANNOTATION)

        # Runtime choice matters for a full Flutter app, not just the tests.
        # LLVM's clang_rt.asan_dynamic loads AFTER ucrtbase in the dependency
        # graph, so allocations made during CRT/COM startup are unhooked; when
        # combase/ole32 later free them through ASan's interceptors LLVM's
        # runtime aborts with an unsuppressible bad-free and the app never
        # renders a frame. Microsoft's ASan runtime (shipped with VS BuildTools)
        # tracks Windows heap ownership correctly and passes those foreign frees
        # through, so the instrumented app runs clean. Both toolchains name the
        # import lib and thunk identically (clang_rt.asan_dynamic-x86_64.lib,
        # clang_rt.asan_dynamic_runtime_thunk-x86_64.lib) and the compiler
        # instrumentation interface is a subset of Microsoft's runtime exports,
        # so we simply point the link search at Microsoft's lib\x64 while keeping
        # clang's own instrumentation. Stage the matching
        # clang_rt.asan_dynamic-x86_64.dll from the same VC\Tools\MSVC\<ver> next
        # to the app exe at run time (Start-Windows.ps1 does this).
        set(_ASAN_LINK_DIR "")
        if(DEFINED ENV{VCToolsInstallDir})
          file(TO_CMAKE_PATH "$ENV{VCToolsInstallDir}" _VCTOOLS)
          if(EXISTS "${_VCTOOLS}/lib/x64/clang_rt.asan_dynamic_runtime_thunk-x86_64.lib")
            set(_ASAN_LINK_DIR "${_VCTOOLS}/lib/x64")
          endif()
        endif()
        if(NOT _ASAN_LINK_DIR)
          file(GLOB _MSVC_ASAN_LIB_DIRS
               "C:/Program Files*/Microsoft Visual Studio/*/BuildTools/VC/Tools/MSVC/*/lib/x64")
          foreach(_d ${_MSVC_ASAN_LIB_DIRS})
            if(EXISTS "${_d}/clang_rt.asan_dynamic_runtime_thunk-x86_64.lib")
              set(_ASAN_LINK_DIR "${_d}")
            endif()
          endforeach()
        endif()
        if(NOT _ASAN_LINK_DIR AND _CLANG_RUNTIME_DIR)
          # Fallback: LLVM's own runtime (fine for the standalone test/fuzz exes;
          # will abort a full Flutter app as described above).
          set(_ASAN_LINK_DIR "${_CLANG_RUNTIME_DIR}")
          message(WARNING "Microsoft ASan runtime not found; falling back to LLVM's clang_rt "
                          "(the full Flutter app will abort on startup under this runtime).")
        endif()

        if(_ASAN_LINK_DIR)
          set(_ASAN_DYNAMIC_LIB "${_ASAN_LINK_DIR}/clang_rt.asan_dynamic-x86_64.lib")
          set(_ASAN_THUNK_LIB "${_ASAN_LINK_DIR}/clang_rt.asan_dynamic_runtime_thunk-x86_64.lib")
          if(EXISTS "${_ASAN_DYNAMIC_LIB}" AND EXISTS "${_ASAN_THUNK_LIB}")
            message(STATUS "clang-cl ASan runtime link dir: ${_ASAN_LINK_DIR}")
            target_link_directories(${project_name} INTERFACE "${_ASAN_LINK_DIR}")
            target_link_libraries(${project_name} INTERFACE clang_rt.asan_dynamic-x86_64
                                                            clang_rt.asan_dynamic_runtime_thunk-x86_64)
            target_link_options(${project_name} INTERFACE /WHOLEARCHIVE:clang_rt.asan_dynamic_runtime_thunk-x86_64.lib)
          else()
            message(WARNING "clang-cl ASan runtime libraries not found in ${_ASAN_LINK_DIR}")
          endif()
        else()
          message(WARNING "Unable to locate a clang-cl ASan runtime for linkage")
        endif()
      endif()
    elseif(MSVC)
      string(FIND "$ENV{PATH}" "$ENV{VSINSTALLDIR}" index_of_vs_install_dir)
      if("${index_of_vs_install_dir}" STREQUAL "-1")
        message(
          SEND_ERROR
            "Using MSVC sanitizers requires setting the MSVC environment before building the project. Please manually open the MSVC command prompt and rebuild the project."
        )
      endif()
      target_compile_options(${project_name} INTERFACE /fsanitize=${LIST_OF_SANITIZERS} /Zi /INCREMENTAL:NO)
      target_compile_definitions(${project_name} INTERFACE _DISABLE_VECTOR_ANNOTATION _DISABLE_STRING_ANNOTATION _DISABLE_OPTIONAL_ANNOTATION)
      target_link_options(${project_name} INTERFACE /INCREMENTAL:NO)
    else()
      target_compile_options(${project_name} INTERFACE -fsanitize=${LIST_OF_SANITIZERS})
      target_link_options(${project_name} INTERFACE -fsanitize=${LIST_OF_SANITIZERS})
    endif()
  endif()

endfunction()
