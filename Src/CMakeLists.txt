# update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}../ExternalLib/)

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
   corrosion_set_env_vars(
              rusty_code
              CXXFLAGS=-fexceptions
    ) 
  endif()
  

  corrosion_add_cxxbridge(
    rusty_bridge
    CRATE
    rusty_code
    FILES
    lib.rs
    )
  
endif()

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
         ${KataglyphisCppProject_HEADERS})

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

if(TARGET ${PROJECT_NAME} AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(STATUS "GCC detected — adding -MMD -MP to target ${PROJECT_NAME}")
  target_compile_options(${PROJECT_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-MMD -MP>
  )
endif()
