include(GoogleTest)
include(${CMAKE_CURRENT_LIST_DIR}/../cmake/CommonTestBuild.cmake)

# Same gate as the FUZZTEST subdirectory in third_party/CMakeLists.txt, which defines link_fuzztest.
if(COMMAND link_fuzztest)
  set(FUZZ_TEST_SUITE fuzzTestSuite)
  file(
    GLOB
    KataglyphisCppProject_FUZZ_TEST_FILTER
    CONFIGURE_DEPENDS
    "*.cpp")
  add_executable(${FUZZ_TEST_SUITE} ${KataglyphisCppProject_FUZZ_TEST_FILTER})

  kataglyphis_configure_common_test_target(${FUZZ_TEST_SUITE} "/../Resources/" "/../Src/")
  kataglyphis_configure_library_test_target(${FUZZ_TEST_SUITE})
  # myproject_options carries the sanitizer and exception flags the library's module BMIs were built with.
  target_link_libraries(${FUZZ_TEST_SUITE} PRIVATE myproject_options ${PROJECT_NAME})
  if(MSVC AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    # absl's swisstable layout follows ASan, which clang-cl leaves off absl and FuzzTest: the suite must match them.
    add_library(kataglyphis_fuzz_unsanitized INTERFACE)
    target_compile_options(kataglyphis_fuzz_unsanitized INTERFACE -fno-sanitize=address,undefined)
    target_link_libraries(${FUZZ_TEST_SUITE} PRIVATE kataglyphis_fuzz_unsanitized)
  endif()

  link_fuzztest(${FUZZ_TEST_SUITE})
  kataglyphis_configure_gtest_discovery(${FUZZ_TEST_SUITE})
  kataglyphis_link_rust_target_if_enabled(${FUZZ_TEST_SUITE})
endif()
