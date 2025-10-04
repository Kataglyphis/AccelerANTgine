set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}ExternalLib/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)

include(cmake/SetTestFilters.cmake)

set(PERF_TEST_SUITE perfTestSuite)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES
     # RELATIVE ${PROJECT_SRC_DIR}
     "${PROJECT_SRC_DIR}/*.cpp")

# Specify the file to exclude
list(REMOVE_ITEM KataglyphisCppProject_SOURCES "${PROJECT_SRC_DIR}/Main.cpp")

file(GLOB_RECURSE KataglyphisCppProject_HEADERS
     # RELATIVE ${PROJECT_SRC_DIR}
     "${PROJECT_SRC_DIR}/*.hpp")

# if(RUST_FEATURES)
#   corrosion_import_crate(MANIFEST_PATH ${PROJECT_SRC_DIR}rusty_code/Cargo.toml)
#   corrosion_add_cxxbridge(rusty_bridge_perf CRATE rusty_code FILES lib.rs)
# endif()

add_executable(${PERF_TEST_SUITE})

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

configure_file(${PROJECT_SRC_DIR}/KataglyphisCppProjectConfig.hpp.in
               "${PROJECT_SRC_DIR}/KataglyphisCppProjectConfig.hpp")

target_sources(
  ${PERF_TEST_SUITE}
  PUBLIC ${PERF_TEST_FILTER} ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         HEADERS
         BASE_DIRS
         ${PROJECT_INCLUDE_DIR}
         FILES
         ${KataglyphisCppProject_HEADERS})

target_link_libraries(
  ${PERF_TEST_SUITE}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         myproject_options
         myproject_warnings
  PRIVATE benchmark::benchmark
          benchmark::benchmark_main
          GSL
          spdlog)

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
