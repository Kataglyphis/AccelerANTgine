set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)

include(cmake/SetTestFilters.cmake)
include(${WORKING_DIRECTORY}Test/cmake/CommonTestBuild.cmake)

set(PERF_TEST_SUITE perfTestSuite)

# if(RUST_FEATURES)
#   corrosion_import_crate(MANIFEST_PATH ${PROJECT_SRC_DIR}rusty_code/Cargo.toml)
#   corrosion_add_cxxbridge(rusty_bridge_perf CRATE rusty_code FILES lib.rs)
# endif()

add_executable(${PERF_TEST_SUITE})

target_compile_definitions(${PERF_TEST_SUITE} PRIVATE KATAGLYPHIS_EXPORTS)

set(_perf_resource_path "/../Resources/")
set(_perf_include_path "/../Src/")
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
  set(_perf_resource_path "/../../Resources/")
  set(_perf_include_path "/../../Src/")
endif()

kataglyphis_configure_common_test_target(${PERF_TEST_SUITE} "${_perf_resource_path}" "${_perf_include_path}")

target_sources(${PERF_TEST_SUITE} PRIVATE ${PERF_TEST_FILTER})

target_link_libraries(
  ${PERF_TEST_SUITE}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         myproject_options
         myproject_warnings
  PRIVATE benchmark::benchmark
          benchmark::benchmark_main
          GSL
          spdlog
          ${PROJECT_NAME})

kataglyphis_link_rust_target_if_enabled(${PERF_TEST_SUITE})
