include(GoogleTest)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NOT (CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo"))
  message(STATUS "This is a Linux system.")

  # Fuzz testing needs special treatment only in debug mode!
  if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")

    fuzztest_setup_fuzzing_flags()

    add_executable(first_fuzz_test dummy.cpp)

    link_fuzztest(first_fuzz_test)
    gtest_discover_tests(first_fuzz_test)
  endif()
endif()
