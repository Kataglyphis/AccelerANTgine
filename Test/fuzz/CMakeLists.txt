include(GoogleTest)
include(${CMAKE_CURRENT_LIST_DIR}/../cmake/CommonTestBuild.cmake)

if(CMAKE_BUILD_TYPE STREQUAL "Debug"
   AND CMAKE_CXX_COMPILER_ID MATCHES ".*Clang"
   AND (CMAKE_SYSTEM_NAME STREQUAL "Linux" OR WIN32))
  add_executable(first_fuzz_test dummy.cpp)

  link_fuzztest(first_fuzz_test)
  kataglyphis_configure_gtest_discovery(first_fuzz_test)
endif()
