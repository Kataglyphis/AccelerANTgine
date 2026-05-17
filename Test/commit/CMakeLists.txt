include(GoogleTest)

# all testing related stuff
set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)
include(${WORKING_DIRECTORY}Test/cmake/CommonTestBuild.cmake)

set(COMMIT_TEST_SUITE commitTestSuite)

file(GLOB_RECURSE KataglyphisCppProject_COMMIT_TEST_FILTER "*.cpp")

message("Commit test filter is: ${KataglyphisCppProject_COMMIT_TEST_FILTER}")

# if(RUST_FEATURES)
#   corrosion_import_crate(MANIFEST_PATH ${PROJECT_SRC_DIR}rusty_code/Cargo.toml)
#   corrosion_add_cxxbridge(rusty_bridge_commit CRATE rusty_code FILES lib.rs)
# endif()

add_executable(${COMMIT_TEST_SUITE})

set(_commit_resource_path "/../../../Resources/")
set(_commit_include_path "/../../../Src/")
if(NOT MSVC)
else()
  set(_commit_resource_path "/../Resources/")
  set(_commit_include_path "/../Src/")
endif()

kataglyphis_configure_common_test_target(${COMMIT_TEST_SUITE} "${_commit_resource_path}" "${_commit_include_path}")

target_sources(
  ${COMMIT_TEST_SUITE}
  PRIVATE ${KataglyphisCppProject_COMMIT_TEST_FILTER})

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
      spdlog
      ${PROJECT_NAME})

kataglyphis_configure_gtest_discovery(${COMMIT_TEST_SUITE})

kataglyphis_link_rust_target_if_enabled(${COMMIT_TEST_SUITE})
