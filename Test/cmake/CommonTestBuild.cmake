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
  kataglyphis_embed_text_file(${target_name} "${PROJECT_SOURCE_DIR}/third_party/ModelANT/contracts/inference-v1.json"
                              kInferenceContract)
endfunction()

# Generated at configure, never stored: third_party/ANTfrastructure/docs/language-ai.md#the-test-model
function(kataglyphis_use_tiny_genai_model target_name)
  set(_model "${CMAKE_BINARY_DIR}/test-models/tiny-genai")
  get_property(_written GLOBAL PROPERTY KATAGLYPHIS_TINY_GENAI_WRITTEN)
  if(NOT _written)
    find_package(
      Python3
      COMPONENTS Interpreter
      REQUIRED)
    execute_process(
      COMMAND
        "${Python3_EXECUTABLE}" -I
        "${PROJECT_SOURCE_DIR}/third_party/ANTfrastructure/linux/scripts/lib/tiny-genai-model.py" --out "${_model}"
      OUTPUT_QUIET COMMAND_ERROR_IS_FATAL ANY)
    set_property(GLOBAL PROPERTY KATAGLYPHIS_TINY_GENAI_WRITTEN TRUE)
  endif()
  target_sources(${target_name} PRIVATE "${PROJECT_SOURCE_DIR}/Test/common/kataglyphis_test_paths.cpp")
  # A staged suite, or one whose build tree moved, finds the model beside itself.
  add_custom_command(
    TARGET ${target_name}
    POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${_model}" "$<TARGET_FILE_DIR:${target_name}>/test-models/tiny-genai")
  target_compile_definitions(${target_name} PRIVATE KATAGLYPHIS_TINY_GENAI_MODEL="${_model}")
endfunction()
