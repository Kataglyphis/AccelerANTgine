include(GoogleTest)

set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)
include(${WORKING_DIRECTORY}Test/cmake/CommonTestBuild.cmake)

set(COMPILE_TEST_SUITE compileTestSuite)

file(GLOB_RECURSE KataglyphisCppProject_COMPILE_TEST_FILTER "*.cpp")

message("Compile test filter is: ${KataglyphisCppProject_COMPILE_TEST_FILTER}")

add_executable(${COMPILE_TEST_SUITE})

set(_compile_resource_path "/../../../Resources/")
set(_compile_include_path "/../../../Src/")
if(NOT MSVC)
else()
  set(_compile_resource_path "/../../Resources")
  set(_compile_include_path "/../../Src/")
endif()

kataglyphis_configure_common_test_target(${COMPILE_TEST_SUITE} "${_compile_resource_path}" "${_compile_include_path}")

target_sources(
  ${COMPILE_TEST_SUITE}
  PRIVATE ${KataglyphisCppProject_COMPILE_TEST_FILTER})

target_link_libraries(
  ${COMPILE_TEST_SUITE}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE gtest_main
          gtest
          GSL
      spdlog
      ${PROJECT_NAME})

kataglyphis_configure_gtest_discovery(${COMPILE_TEST_SUITE})

kataglyphis_link_rust_target_if_enabled(${COMPILE_TEST_SUITE})
