# Src/CMakeLists.txt
# update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ExternalLib/")

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_MODULES "*.ixx")
list(REMOVE_ITEM KataglyphisCppProject_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/cli_main.cpp")

set(KataglyphisCppProjectConfig_MODULE_IN
  "${CMAKE_CURRENT_SOURCE_DIR}/KataglyphisCppProjectConfig.ixx.in")
set(KataglyphisCppProjectConfig_MODULE_OUT
  "${CMAKE_CURRENT_BINARY_DIR}/KataglyphisCppProjectConfig.ixx")
configure_file(${KataglyphisCppProjectConfig_MODULE_IN} ${KataglyphisCppProjectConfig_MODULE_OUT} @ONLY)
list(APPEND KataglyphisCppProject_MODULES ${KataglyphisCppProjectConfig_MODULE_OUT})

if(RUST_FEATURES)
  corrosion_import_crate(MANIFEST_PATH rusty_code/Cargo.toml)

  # Keep Rust bridge compilers aligned with the configured CMake toolchain.
  set(RUST_CC "${CMAKE_C_COMPILER}")
  set(RUST_CXX "${CMAKE_CXX_COMPILER}")
  if(NOT RUST_CC)
    set(RUST_CC "cc")
  endif()
  if(NOT RUST_CXX)
    set(RUST_CXX "c++")
  endif()

  if(WIN32)
    corrosion_set_env_vars(
      rusty_code
      CC=${RUST_CC}
      CXX=${RUST_CXX}
      CXXFLAGS=/EHsc)
  else()
    # Native-only corrosion/toolchain setup (no cross-building).
    if(NOT DEFINED MYPROJECT_GCC_TOOLCHAIN_PATH)
      set(MYPROJECT_GCC_TOOLCHAIN_PATH
          ""
          CACHE PATH "Optional GCC toolchain root")
    endif()

    # For Clang, optionally point to a GCC toolchain for libstdc++/headers.
    set(_gcc_toolchain_root "")
    if(MYPROJECT_GCC_TOOLCHAIN_PATH AND EXISTS "${MYPROJECT_GCC_TOOLCHAIN_PATH}")
      set(_gcc_toolchain_root "${MYPROJECT_GCC_TOOLCHAIN_PATH}")
    elseif(DEFINED MYPROJECT_GCC_TOOLCHAIN_PATH_DEFAULT AND EXISTS "${MYPROJECT_GCC_TOOLCHAIN_PATH_DEFAULT}")
      set(_gcc_toolchain_root "${MYPROJECT_GCC_TOOLCHAIN_PATH_DEFAULT}")
    endif()

    set(RUST_CXXFLAGS "-fexceptions")
    if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND _gcc_toolchain_root)
      set(RUST_CXXFLAGS "--gcc-toolchain=${_gcc_toolchain_root} ${RUST_CXXFLAGS}")
    endif()
    if(DEFINED ENV{CXXFLAGS} AND NOT "$ENV{CXXFLAGS}" STREQUAL "")
      set(RUST_CXXFLAGS "$ENV{CXXFLAGS} ${RUST_CXXFLAGS}")
    endif()

    # Set deterministic env for corrosion on non-Windows hosts.
    corrosion_set_env_vars(
      rusty_code
      CC=${RUST_CC}
      CXX=${RUST_CXX}
      "CXXFLAGS=${RUST_CXXFLAGS}")

    message(STATUS "Configured native corrosion: CC=${RUST_CC} CXX=${RUST_CXX} CXXFLAGS=${RUST_CXXFLAGS}")

  endif() # end non-WIN32 branch

  corrosion_add_cxxbridge(
    rusty_bridge
    CRATE
    rusty_code
    FILES
    lib.rs)

endif() # end RUST_FEATURES

# add the executable
add_library(${PROJECT_NAME} SHARED)
set_target_properties(
  ${PROJECT_NAME}
  PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
             LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
             RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
# Enable module scanning on project targets so CMake can generate dyndep/BMI ordering.
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_SCAN_FOR_MODULES ON)
# add_executable(${PROJECT_NAME})

if(PROJECT_IS_TOP_LEVEL)
  if(MYPROJECT_USE_CPP_MODULES)
    add_executable(${PROJECT_NAME}_cli cli_main.cpp)
    set_target_properties(${PROJECT_NAME}_cli PROPERTIES OUTPUT_NAME "${PROJECT_NAME}" RUNTIME_OUTPUT_DIRECTORY
                                               "${CMAKE_BINARY_DIR}/bin")
    set_target_properties(${PROJECT_NAME}_cli PROPERTIES CXX_SCAN_FOR_MODULES ON)
  else()
    message(STATUS "Skipping ${PROJECT_NAME}_cli: requires C++ modules")
  endif()
endif()

target_compile_features(${PROJECT_NAME} PUBLIC cxx_std_23)
if(TARGET ${PROJECT_NAME}_cli)
  target_compile_features(${PROJECT_NAME}_cli PRIVATE cxx_std_23)
endif()

# Define export macro for building the DLL
target_compile_definitions(${PROJECT_NAME} PRIVATE KATAGLYPHIS_EXPORTS)

# Set symbol visibility
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)

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
  target_compile_definitions(${PROJECT_NAME} PRIVATE RELATIVE_RESOURCE_PATH="/../../Resources/"
                                                     RELATIVE_INCLUDE_PATH="/../../Src/")
else()
  target_compile_definitions(${PROJECT_NAME} PRIVATE RELATIVE_RESOURCE_PATH="/../Resources/"
                                                     RELATIVE_INCLUDE_PATH="/../Src/")
endif()

target_sources(
  ${PROJECT_NAME}
  PRIVATE ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         CXX_MODULES
         BASE_DIRS
         ${PROJECT_SRC_DIR}
         ${CMAKE_CURRENT_BINARY_DIR}
         FILES
         ${KataglyphisCppProject_MODULES})

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE GSL spdlog::spdlog nlohmann_json::nlohmann_json)

if(RUST_FEATURES)
  target_link_libraries(${PROJECT_NAME} PUBLIC rusty_code)
endif()

if(TARGET ${PROJECT_NAME}_cli)
  target_link_libraries(${PROJECT_NAME}_cli PRIVATE ${PROJECT_NAME})
endif()

if(UNIX AND NOT APPLE)
  target_compile_options(${PROJECT_NAME} PUBLIC -pthread)
  target_link_options(${PROJECT_NAME} PUBLIC -pthread)
endif()

if(TARGET ${PROJECT_NAME} AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(STATUS "GCC detected — adding -MMD -MP to target ${PROJECT_NAME}")
  target_compile_options(${PROJECT_NAME} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-MMD -MP>)
endif()
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  set_property(SOURCE ${KataglyphisCppProject_MODULES} APPEND PROPERTY COMPILE_OPTIONS "-fno-sanitize=undefined")
endif()
