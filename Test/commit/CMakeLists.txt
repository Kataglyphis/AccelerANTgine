include(GoogleTest)

# all testing related stuff
set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)

set(COMMIT_TEST_SUITE commitTestSuite)

file(GLOB_RECURSE KataglyphisCppProject_COMMIT_TEST_FILTER "*.cpp")

message("Commit test filter is: ${KataglyphisCppProject_COMMIT_TEST_FILTER}")

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "${PROJECT_SRC_DIR}/*.cpp")

# Specify the file to exclude
list(REMOVE_ITEM KataglyphisCppProject_SOURCES "${PROJECT_SRC_DIR}/Main.cpp")

file(GLOB_RECURSE KataglyphisCppProject_HEADERS "${PROJECT_SRC_DIR}/*.hpp")

# if(RUST_FEATURES)
#   corrosion_import_crate(MANIFEST_PATH ${PROJECT_SRC_DIR}rusty_code/Cargo.toml)
#   corrosion_add_cxxbridge(rusty_bridge_commit CRATE rusty_code FILES lib.rs)
# endif()

add_executable(${COMMIT_TEST_SUITE})

if(RUST_FEATURES)
  target_compile_definitions(${COMMIT_TEST_SUITE} PRIVATE USE_RUST=1)
else()
  target_compile_definitions(${COMMIT_TEST_SUITE} PRIVATE USE_RUST=0)
endif()

if(NOT MSVC)
  target_compile_definitions(${COMMIT_TEST_SUITE} PRIVATE RELATIVE_RESOURCE_PATH="/../../../Resources/"
                                                          RELATIVE_INCLUDE_PATH="/../../../Src/")
else()
  target_compile_definitions(${COMMIT_TEST_SUITE} PRIVATE RELATIVE_RESOURCE_PATH="/../Resources/"
                                                          RELATIVE_INCLUDE_PATH="/../Src/")
endif()

configure_file(${PROJECT_SRC_DIR}/KataglyphisCppProjectConfig.hpp.in
               "${PROJECT_SRC_DIR}/KataglyphisCppProjectConfig.hpp")

target_sources(
  ${COMMIT_TEST_SUITE}
  PUBLIC ${KataglyphisCppProject_COMMIT_TEST_FILTER} ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         HEADERS
         BASE_DIRS
         ${PROJECT_INCLUDE_DIR}
         FILES
         ${KataglyphisCppProject_HEADERS})

target_link_libraries(
  ${COMMIT_TEST_SUITE}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE gtest
          gtest_main
          GSL
          spdlog)

if(NOT WINDOWS_CI)
  message(STATUS "WINDOWS_CI is OFF or not defined.")
  gtest_discover_tests(${COMMIT_TEST_SUITE} DISCOVERY_TIMEOUT 300)
else()
  message(STATUS "WINDOWS_CI is OFF or not defined.")
endif()

if(RUST_FEATURES)
  target_link_libraries(${COMMIT_TEST_SUITE} PUBLIC rusty_code)
endif()

# disable all warnings for our test suite
if(MSVC)
  target_compile_options(${COMMIT_TEST_SUITE} INTERFACE /w)
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  target_compile_options(${COMMIT_TEST_SUITE} INTERFACE -w)
else()
  target_compile_options(${COMMIT_TEST_SUITE} INTERFACE -w)
endif()
