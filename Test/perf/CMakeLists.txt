set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)

include(cmake/SetTestFilters.cmake)

set(PERF_TEST_SUITE perfTestSuite)

# if(RUST_FEATURES)
#   corrosion_import_crate(MANIFEST_PATH ${PROJECT_SRC_DIR}rusty_code/Cargo.toml)
#   corrosion_add_cxxbridge(rusty_bridge_perf CRATE rusty_code FILES lib.rs)
# endif()

add_executable(${PERF_TEST_SUITE})

target_compile_definitions(${PERF_TEST_SUITE} PRIVATE KATAGLYPHIS_EXPORTS)

if(RUST_FEATURES)
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=1)
else()
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=0)
endif()

if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
  target_compile_definitions(${PERF_TEST_SUITE} PRIVATE RELATIVE_RESOURCE_PATH="/../../Resources/"
                                                        RELATIVE_INCLUDE_PATH="/../../Src/")
else()
  target_compile_definitions(${PERF_TEST_SUITE} PRIVATE RELATIVE_RESOURCE_PATH="/../Resources/"
                                                        RELATIVE_INCLUDE_PATH="/../Src/")
endif()

target_sources(
  ${PERF_TEST_SUITE}
  PRIVATE ${PERF_TEST_FILTER})

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

if(RUST_FEATURES)
  target_link_libraries(${PERF_TEST_SUITE} PUBLIC rusty_code)
endif()

# disable all warnings for our test suite
if(MSVC)
  target_compile_options(${PERF_TEST_SUITE} INTERFACE /w)
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  target_compile_options(${PERF_TEST_SUITE} INTERFACE -w)
else()
  target_compile_options(${PERF_TEST_SUITE} INTERFACE -w)
endif()
