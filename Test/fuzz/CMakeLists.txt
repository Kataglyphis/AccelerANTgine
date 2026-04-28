include(GoogleTest)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NOT (CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo"))
  message(STATUS "This is a Linux system.")

  # Fuzz testing needs special treatment only in debug mode!
  if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")

    add_executable(first_fuzz_test dummy.cpp)

    if(KATAGLYPHIS_ENABLE_FUZZTEST_FUZZING_MODE OR (FUZZTEST_COMPATIBILITY_MODE STREQUAL "libfuzzer"))
      target_compile_options(
        first_fuzz_test
        PRIVATE -g
                -UNDEBUG
                -fsanitize=address
                -fsanitize-coverage=inline-8bit-counters
                -fsanitize-coverage=trace-cmp)
      target_compile_definitions(first_fuzz_test PRIVATE FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION ADDRESS_SANITIZER)
      target_link_options(first_fuzz_test PRIVATE -fsanitize=address)
    endif()

    if(FUZZTEST_COMPATIBILITY_MODE STREQUAL "libfuzzer")
      target_compile_options(first_fuzz_test PRIVATE -fsanitize=fuzzer-no-link)
      target_compile_definitions(first_fuzz_test PRIVATE FUZZTEST_COMPATIBILITY_MODE)
    endif()

    link_fuzztest(first_fuzz_test)
    gtest_discover_tests(first_fuzz_test)
  endif()
endif()

# ClangCL libFuzzer target on Windows
#
# The prebuilt clang_rt.fuzzer-x86_64.lib is linked against the static CRT (/MT).
# When this library is available, the target is built with /MT to match the
# static CRT fuzzer runtime.  For LLVM >= 19, clang_rt.fuzzer_dynamic-x86_64.lib
# (built with /MD) is also available for builds using the dynamic CRT.
if(WIN32
   AND MSVC
   AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
   AND CMAKE_BUILD_TYPE STREQUAL "Debug")

  # Detect the clang resource directory and check for the dynamic-CRT fuzzer runtime
  execute_process(
    COMMAND ${CMAKE_CXX_COMPILER} --print-resource-dir
    OUTPUT_VARIABLE _FUZZER_CLANG_RESOURCE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)

  set(_FUZZER_DYNAMIC_LIB_AVAILABLE FALSE)
  set(_FUZZER_STATIC_LIB_AVAILABLE FALSE)
  if(_FUZZER_CLANG_RESOURCE_DIR)
    set(_FUZZER_RUNTIME_DIR "${_FUZZER_CLANG_RESOURCE_DIR}/lib/windows")
    set(_FUZZER_DYNAMIC_LIB "${_FUZZER_RUNTIME_DIR}/clang_rt.fuzzer_dynamic-x86_64.lib")
    set(_FUZZER_STATIC_LIB "${_FUZZER_RUNTIME_DIR}/clang_rt.fuzzer-x86_64.lib")
    if(EXISTS "${_FUZZER_DYNAMIC_LIB}")
      set(_FUZZER_DYNAMIC_LIB_AVAILABLE TRUE)
    endif()
    if(EXISTS "${_FUZZER_STATIC_LIB}")
      set(_FUZZER_STATIC_LIB_AVAILABLE TRUE)
    endif()
  endif()

  if(_FUZZER_DYNAMIC_LIB_AVAILABLE)
    message(STATUS "Configuring libFuzzer harness for clang-cl on Windows (dynamic CRT)")
    add_executable(kataglyphis_libfuzzer libfuzzer_harness.cpp)
    target_compile_features(kataglyphis_libfuzzer PRIVATE cxx_std_23)
    set_target_properties(kataglyphis_libfuzzer PROPERTIES CXX_SCAN_FOR_MODULES ON)
    target_compile_options(kataglyphis_libfuzzer PRIVATE /clang:-fsanitize=fuzzer /clang:-fsanitize=address)
    target_compile_definitions(kataglyphis_libfuzzer PRIVATE KATAGLYPHIS_EXPORTS)
    target_link_directories(kataglyphis_libfuzzer PRIVATE "${_FUZZER_RUNTIME_DIR}")
    target_link_libraries(
      kataglyphis_libfuzzer
      PRIVATE clang_rt.fuzzer_dynamic-x86_64
              ${PROJECT_NAME}
              ${CMAKE_DL_LIBS}
              Threads::Threads)
    message(STATUS "libFuzzer runtime (dynamic CRT) found: ${_FUZZER_DYNAMIC_LIB}")
  elseif(_FUZZER_STATIC_LIB_AVAILABLE)
    message(STATUS "Configuring libFuzzer harness for clang-cl on Windows (static CRT /MT)")
    add_executable(kataglyphis_libfuzzer libfuzzer_harness.cpp)
    target_compile_features(kataglyphis_libfuzzer PRIVATE cxx_std_23)
    set_target_properties(kataglyphis_libfuzzer PROPERTIES CXX_SCAN_FOR_MODULES ON)
    target_compile_options(kataglyphis_libfuzzer PRIVATE /clang:-fsanitize=fuzzer /clang:-fsanitize=address /MT)
    target_compile_definitions(kataglyphis_libfuzzer PRIVATE KATAGLYPHIS_EXPORTS)
    target_link_directories(kataglyphis_libfuzzer PRIVATE "${_FUZZER_RUNTIME_DIR}")
    target_link_libraries(
      kataglyphis_libfuzzer
      PRIVATE clang_rt.fuzzer-x86_64
              ${PROJECT_NAME}
              ${CMAKE_DL_LIBS}
              Threads::Threads)
    message(STATUS "libFuzzer runtime (static CRT /MT) found: ${_FUZZER_STATIC_LIB}")
  else()
    message(WARNING
      "Skipping libFuzzer harness for clang-cl on Windows: "
      "No clang_rt.fuzzer-x86_64.lib found in resource directory.")
  endif()
endif()