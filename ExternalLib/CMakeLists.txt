include(FetchContent)

# include google test to project
if(BUILD_TESTING)
  FetchContent_Declare(googletest
                       URL https://github.com/google/googletest/archive/56efe3983185e3f37e43415d1afa97e3860f187f.zip)
  set(gtest_force_shared_crt
      ON
      CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
endif()
# For Windows: Prevent overriding the parent project's compiler/linker settings

# We will not need to test benchmark lib itself.
set(BENCHMARK_ENABLE_TESTING
    OFF
    CACHE BOOL "Disable benchmark testing as we don't need it.")
# We will not need to test benchmark lib itself.
set(BENCHMARK_INSTALL_DOCS
    OFF
    CACHE BOOL "Disable benchmark testing as we don't need it.")
# We will not need to install benchmark since we link it statically.
set(BENCHMARK_ENABLE_INSTALL
    OFF
    CACHE BOOL "Disable benchmark install to avoid overwriting vendor install.")
set(BENCHMARK_USE_BUNDLED_GTEST
    OFF
    CACHE BOOL "Disable the bundled GTest usage.")

# Avoid failing feature checks for regex backends in cross/CI builds.
# Google Benchmark will compile with POSIX regex on Linux and does not require
# runtime feature checks for our use-case (no benchmark tests are built).
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(HAVE_POSIX_REGEX
    ON
    CACHE BOOL "Force POSIX regex for Google Benchmark" FORCE)
endif()

add_subdirectory(GOOGLE_BENCHMARK)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND BUILD_TESTING AND NOT(CMAKE_BUILD_TYPE STREQUAL "Profile" ))
  message(STATUS "This is a Linux system.")
  # # Detect target architecture
  # string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" TARGET_ARCH)
  # message(STATUS "Detected architecture: ${TARGET_ARCH}")

  # # Check if not ARM
  # if(NOT TARGET_ARCH MATCHES "^(arm|aarch64)")
  if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")

    message("Adding Fuzztest")
    add_subdirectory(FUZZTEST)
    if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
      set(FUZZTEST_FUZZING_MODE
          ON
          CACHE BOOL "" FORCE)
    endif()
    # endif()
  endif()
endif()

FetchContent_Declare(
  GSL
  GIT_REPOSITORY "https://github.com/microsoft/GSL"
  GIT_TAG "v4.2.1")
FetchContent_MakeAvailable(GSL)

if(myproject_DISABLE_EXCEPTIONS)
  set(SPDLOG_NO_EXCEPTIONS
      ON
      CACHE BOOL "Disable SPDLOG exceptions.")
endif()
# set spdlog options before adding it
set(SPDLOG_BUILD_EXAMPLES OFF  CACHE BOOL "Disable spdlog examples" FORCE)
set(SPDLOG_BUILD_TESTS    OFF  CACHE BOOL "Disable spdlog tests"    FORCE)
set(SPDLOG_BUILD_BENCH    OFF  CACHE BOOL "Disable spdlog bench"    FORCE)
set(SPDLOG_INSTALL        OFF  CACHE BOOL "Disable spdlog install"  FORCE)
set(SPDLOG_FMT_EXTERNAL   OFF   CACHE BOOL "Use external fmt"         FORCE)

add_subdirectory(SPDLOG)

add_subdirectory(NLOHMANN_JSON)

if(RUST_FEATURES)

  FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG master)
  FetchContent_MakeAvailable(Corrosion)

  find_program(CXXBRIDGE cxxbridge PATHS "$ENV{HOME}/.cargo/bin/")
  if(CXXBRIDGE STREQUAL "CXXBRIDGE-NOTFOUND")
    message("Could not find cxxbridge, trying to install with `cargo install cxxbridge-cmd'")
    find_program(CARGO cargo PATHS "$ENV{HOME}/.cargo/bin/")
    if(CARGO STREQUAL "CARGO-NOTFOUND")
      message(FATAL_ERROR "Requires cargo available in path, install via rustup https://rustup.rs/")
    endif()
    execute_process(COMMAND ${CARGO} install cxxbridge-cmd)
    find_program(CXXBRIDGE cxxbridge PATHS "$ENV{HOME}/.cargo/bin/")
  endif()

endif()
