include(GoogleTest)

set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)

set(COMPILE_TEST_SUITE compileTestSuite)

file(GLOB_RECURSE KataglyphisCppProject_COMPILE_TEST_FILTER "*.cpp")

message("Compile test filter is: ${KataglyphisCppProject_COMPILE_TEST_FILTER}")

add_executable(${COMPILE_TEST_SUITE})

target_compile_definitions(${COMPILE_TEST_SUITE} PRIVATE KATAGLYPHIS_EXPORTS)

if(RUST_FEATURES)
  target_compile_definitions(${COMPILE_TEST_SUITE} PRIVATE USE_RUST=1)
else()
  target_compile_definitions(${COMPILE_TEST_SUITE} PRIVATE USE_RUST=0)
endif()

if(NOT MSVC)
  target_compile_definitions(${COMPILE_TEST_SUITE} PRIVATE RELATIVE_RESOURCE_PATH="/../../../Resources/"
                                                           RELATIVE_INCLUDE_PATH="/../../../Src/")
else()
  target_compile_definitions(${COMPILE_TEST_SUITE} PRIVATE RELATIVE_RESOURCE_PATH="/../../Resources"
                                                   PUBLIC RELATIVE_INCLUDE_PATH="/../../Src/")
endif()

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

if(NOT WINDOWS_CI)
  message(STATUS "WINDOWS_CI is OFF or not defined.")
  gtest_discover_tests(${COMPILE_TEST_SUITE} DISCOVERY_TIMEOUT 300)
else()
  message(STATUS "WINDOWS_CI is OFF or not defined.")
endif()

if(RUST_FEATURES)
  target_link_libraries(${COMPILE_TEST_SUITE} PUBLIC rusty_code)
endif()

# disable all warnings for our test suite
if(MSVC)
  target_compile_options(${COMPILE_TEST_SUITE} INTERFACE /w)
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  target_compile_options(${COMPILE_TEST_SUITE} INTERFACE -w)
else()
  target_compile_options(${COMPILE_TEST_SUITE} INTERFACE -w)
endif()
