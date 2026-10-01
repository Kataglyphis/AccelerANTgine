# See third_party/ANTfrastructure/cmake/GTestDiscovery.cmake for discovery and its clang-cl fallback.
include(GTestDiscovery)

function(
  kataglyphis_collect_project_sources
  out_sources
  out_headers
  project_src_dir)
  file(GLOB_RECURSE _kataglyphis_sources "${project_src_dir}/*.cpp")
  list(REMOVE_ITEM _kataglyphis_sources "${project_src_dir}/Main.cpp")
  set(${out_sources}
      "${_kataglyphis_sources}"
      PARENT_SCOPE)
endfunction()

function(kataglyphis_add_config_module_to_target target_name project_src_dir)
  get_filename_component(_kataglyphis_project_src_dir "${project_src_dir}" REALPATH)
  set(_kataglyphis_config_module "${_kataglyphis_project_src_dir}/KataglyphisCppProjectConfig.ixx")

  if(NOT EXISTS "${_kataglyphis_config_module}")
    set(_kataglyphis_generated_config_module "${CMAKE_BINARY_DIR}/Src/KataglyphisCppProjectConfig.ixx")
    if(EXISTS "${_kataglyphis_generated_config_module}")
      set(_kataglyphis_config_module "${_kataglyphis_generated_config_module}")
    endif()
  endif()

  if(EXISTS "${_kataglyphis_config_module}")
    set_target_properties(${target_name} PROPERTIES CXX_SCAN_FOR_MODULES ON)
    target_sources(
      ${target_name}
      PRIVATE FILE_SET
              CXX_MODULES
              BASE_DIRS
              "${_kataglyphis_project_src_dir}"
              "${CMAKE_BINARY_DIR}/Src"
              FILES
              "${_kataglyphis_config_module}")
  else()
    message(FATAL_ERROR "Expected config module not found: ${_kataglyphis_config_module}")
  endif()
endfunction()

# Old name kept for the Test/*/CMakeLists.txt call sites; no WORKING_DIRECTORY on purpose (see the module header).
function(kataglyphis_configure_gtest_discovery test_target)
  kataglyphis_register_gtest_target(${test_target})
  # The hub's ENVIRONMENT "PATH=a;b;..." splits at its own semicolons, leaving PATH=<exe dir>; bin\ holds the DLLs.
  if(WIN32 AND TEST ${test_target})
    file(TO_NATIVE_PATH "${CMAKE_BINARY_DIR}/bin" _kataglyphis_bin_dir)
    get_filename_component(_kataglyphis_compiler_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
    file(TO_NATIVE_PATH "${_kataglyphis_compiler_dir}" _kataglyphis_compiler_dir)
    set_property(TEST ${test_target} PROPERTY ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:${_kataglyphis_bin_dir}"
                                              "PATH=path_list_append:${_kataglyphis_compiler_dir}")
  endif()
endfunction()

function(
  kataglyphis_configure_common_test_target
  target_name
  resource_path
  include_path)
  if(RUST_FEATURES)
    target_compile_definitions(${target_name} PRIVATE USE_RUST=1)
  else()
    target_compile_definitions(${target_name} PRIVATE USE_RUST=0)
  endif()

  target_compile_definitions(${target_name} PRIVATE RELATIVE_RESOURCE_PATH="${resource_path}"
                                                    RELATIVE_INCLUDE_PATH="${include_path}")

  # Warnings are graded on the library targets; the suites' own would only add noise.
  if(MSVC)
    target_compile_options(${target_name} PRIVATE /w)
  else()
    target_compile_options(${target_name} PRIVATE -w)
  endif()
endfunction()

# Embeds a text file as `inline constexpr std::string_view <variable>` in <variable>.inc, so staged tests need no data.
function(
  kataglyphis_embed_text_file
  target_name
  source_file
  variable)
  set(_kataglyphis_embed_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
  file(READ "${source_file}" KATAGLYPHIS_EMBEDDED_CONTENT)
  set(KATAGLYPHIS_EMBEDDED_VARIABLE "${variable}")
  file(
    CONFIGURE
    OUTPUT
    "${_kataglyphis_embed_dir}/${variable}.inc"
    CONTENT
    "inline constexpr std::string_view @KATAGLYPHIS_EMBEDDED_VARIABLE@ = R\"kgembed(@KATAGLYPHIS_EMBEDDED_CONTENT@)kgembed\";\n"
    @ONLY)
  set_property(
    DIRECTORY
    APPEND
    PROPERTY CMAKE_CONFIGURE_DEPENDS "${source_file}")
  target_include_directories(${target_name} PRIVATE "${_kataglyphis_embed_dir}")
endfunction()

# A suite that calls the library: it imports its modules, includes the C header and reads the shipped config.
function(kataglyphis_configure_library_test_target target_name)
  set_target_properties(${target_name} PROPERTIES CXX_SCAN_FOR_MODULES ON)
  target_include_directories(${target_name} PRIVATE "${PROJECT_SOURCE_DIR}/Src" "${PROJECT_SOURCE_DIR}/Test/common")
  target_compile_definitions(
    ${target_name} PRIVATE KATAGLYPHIS_TEST_PROJECT_VERSION="${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}")
  kataglyphis_embed_text_file(${target_name} "${PROJECT_SOURCE_DIR}/resources/configs/inference_config.toml"
                              kShippedInferenceConfig)
endfunction()

function(kataglyphis_link_rust_target_if_enabled target_name)
  if(RUST_FEATURES)
    target_link_libraries(${target_name} PUBLIC rusty_code)
  endif()
endfunction()
