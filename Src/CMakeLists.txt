# Src/CMakeLists.txt
# update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ExternalLib/")

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_HEADERS "*.hpp")

if(RUST_FEATURES)

  corrosion_import_crate(
    MANIFEST_PATH rusty_code/Cargo.toml
  )

  if(WIN32)
    corrosion_set_env_vars(
      rusty_code
      CXXFLAGS=/EHsc
    )
  else()
    # Native-only corrosion/toolchain setup (no cross-building)
    # Optionally override with -DGCC_TOOLCHAIN_PATH=/path/to/gcc when configuring
    # Nur setzen, wenn wir im GNU/GCC Preset sind
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0" CACHE PATH "GCC toolchain root")
    else()
        # Falls Clang aktiv ist, leeren wir den Pfad oder setzen ihn auf 'OFF'
        set(GCC_TOOLCHAIN_PATH "" CACHE PATH "GCC toolchain root" FORCE)
    endif()

    # detect host arch for logging (no cross-compile behavior)
    string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _hostproc)
    if(_hostproc MATCHES "^(x86_64|amd64)$")
      set(HOST_ARCH "x86_64")
    elseif(_hostproc MATCHES "^(aarch64|arm64|armv8)$")
      set(HOST_ARCH "aarch64")
    elseif(_hostproc MATCHES "^(riscv64)$")
      set(HOST_ARCH "riscv64")
    else()
      set(HOST_ARCH "${_hostproc}")
    endif()

    message(STATUS "Native-only build. HOST_ARCH=${HOST_ARCH}")

    if(GCC_TOOLCHAIN_PATH AND EXISTS "${GCC_TOOLCHAIN_PATH}")
      # Try to find reasonable native compiler binary names
      if(HOST_ARCH STREQUAL "x86_64")
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
      elseif(HOST_ARCH STREQUAL "aarch64")
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
      elseif(HOST_ARCH STREQUAL "riscv64")
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
      else()
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/g++")
      endif()

      if(NOT GCC_TOOLCHAIN_GCC)
        message(WARNING "Toolchain gcc not found in ${GCC_TOOLCHAIN_PATH}; falling back to system 'gcc'")
        set(GCC_TOOLCHAIN_GCC "gcc")
      endif()
      if(NOT GCC_TOOLCHAIN_GXX)
        message(WARNING "Toolchain g++ not found in ${GCC_TOOLCHAIN_PATH}; falling back to system 'g++'")
        set(GCC_TOOLCHAIN_GXX "g++")
      endif()

      # prefer lib64 then lib; optional for setting LDFLAGS/rpath
      if(EXISTS "${GCC_TOOLCHAIN_PATH}/lib64")
        set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")
      elseif(EXISTS "${GCC_TOOLCHAIN_PATH}/lib")
        set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib")
      else()
        message(WARNING "No lib or lib64 under ${GCC_TOOLCHAIN_PATH}; skipping LDFLAGS/rpath setup")
        unset(GCC_LIB_PATH)
      endif()

      # DO NOT inject toolchain C++ includes. Only set CC/CXX and LDFLAGS/rpath for native run.
      if(GCC_LIB_PATH)
        corrosion_set_env_vars(
          rusty_code
          CC=${GCC_TOOLCHAIN_GCC}
          CXX=${GCC_TOOLCHAIN_GXX}
          CXXFLAGS=-fexceptions
        )
      else()
        corrosion_set_env_vars(
          rusty_code
          CC=${GCC_TOOLCHAIN_GCC}
          CXX=${GCC_TOOLCHAIN_GXX}
          CXXFLAGS=-fexceptions
        )
      endif()

      message(STATUS "Configured native corrosion: CC=${GCC_TOOLCHAIN_GCC} CXX=${GCC_TOOLCHAIN_GXX} ${GCC_LIB_PATH}")
    else()
      message(STATUS "No GCC_TOOLCHAIN_PATH (${GCC_TOOLCHAIN_PATH}) found — using system compilers (native build)")
      # Still set minimal sensible env so corrosion has deterministic env on non-Windows hosts
      corrosion_set_env_vars(
        rusty_code
        CXXFLAGS=-fexceptions
      )
    endif()

  endif() # end non-WIN32 branch

  corrosion_add_cxxbridge(
    rusty_bridge
    CRATE
    rusty_code
    FILES
    lib.rs
  )

endif() # end RUST_FEATURES

# add the executable
add_library(${PROJECT_NAME} SHARED)
set_target_properties(${PROJECT_NAME} PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
# add_executable(${PROJECT_NAME})

# Define export macro for building the DLL
target_compile_definitions(${PROJECT_NAME} PRIVATE KATAGLYPHIS_EXPORTS)

# Set symbol visibility
set_target_properties(${PROJECT_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

if(RUST_FEATURES)
  message("RUST features defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=1)
else()
  message("RUST features not defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=0)
endif()

# Treat MSVC and clang-cl on Windows differently in a sense of deployment
# https://clang.llvm.org/docs/UsersManual.html
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../../Resources/"
      RELATIVE_INCLUDE_PATH="/../../Src/"
  )
else()
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../Resources/"
      RELATIVE_INCLUDE_PATH="/../Src/"
  )
endif()

configure_file(KataglyphisCppProjectConfig.hpp.in "${CMAKE_CURRENT_SOURCE_DIR}/KataglyphisCppProjectConfig.hpp")

target_sources(
  ${PROJECT_NAME}
  PUBLIC ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         HEADERS
         BASE_DIRS
         ${PROJECT_INCLUDE_DIR}
         FILES
         ${KataglyphisCppProject_HEADERS}
)

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE GSL spdlog::spdlog nlohmann_json::nlohmann_json
)

if(RUST_FEATURES)
  target_link_libraries(${PROJECT_NAME} PUBLIC rusty_code)
endif()

if(TARGET ${PROJECT_NAME} AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(STATUS "GCC detected — adding -MMD -MP to target ${PROJECT_NAME}")
  target_compile_options(${PROJECT_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-MMD -MP>
  )
endif()
