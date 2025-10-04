cmake_minimum_required(VERSION 4.1.1)

# set the project name
project(
  KataglyphisCppProject
  VERSION 0.0.1
  DESCRIPTION "Lore ipsum"
  HOMEPAGE_URL "https://jonasheinle.de/"
  LANGUAGES CXX C)

set(AUTHOR "Jonas Heinle")

# Set WINDOWS_CI to OFF by default
# WINDOWS CI is only able to verify successful compiling ... Windows ... lel
# i will stay on linux ...
set(WINDOWS_CI
    OFF
    CACHE BOOL "Enable Windows CI build options")
set(RUST_FEATURES
    ON
    CACHE BOOL "Enable Rust features in our project.")

if(RUST_FEATURES)
  message(STATUS "Rust features are enabled.")
  if(MSVC)
    message(STATUS "On a windows machine you must use MSVC or clang-cl when integrating rust features.")
  endif()
else()
  message(STATUS "Rust features are disabled.")
  message(STATUS "Your are going to use a non MSVC/clang-cl compiler on windows. Therefore no rust integration possible.")
endif()

include(cmake/PreventInSourceBuilds.cmake)
include(cmake/ProjectOptions.cmake)

myproject_setup_options()

myproject_global_options()

message(STATUS "About to call the local options function.")
myproject_local_options()

include(cmake/SystemLibDependencies.cmake)
add_subdirectory(ExternalLib)

if(BUILD_TESTING AND NOT WIN32 AND CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND NOT(CMAKE_BUILD_TYPE STREQUAL "Profile"))
  fuzztest_setup_fuzzing_flags()
endif()

add_subdirectory(Src)

if(NOT WINDOWS_CI AND BUILD_TESTING)
  include(CTest)
  enable_testing()
  message(STATUS "WINDOWS_CI is OFF or not defined.")
else()
  message(STATUS "WINDOWS_CI is OFF or not defined.")
endif()

if(BUILD_TESTING)
  message(STATUS "Tests are enabled.!")
  add_subdirectory(Test/commit)
  add_subdirectory(Test/compile)
  add_subdirectory(Test/perf)
  add_subdirectory(Test/fuzz)
else()
  message(STATUS "Tests are disabled.!")
endif()

# for correct library output needed
install(
  TARGETS ${PROJECT_NAME}
  CONFIGURATIONS Release
  RUNTIME DESTINATION bin)

# we keep the relative paths in the install dir
# keep in mind that install dir will be in front of this relative path ...

include(cmake/CPackOptions.cmake)
