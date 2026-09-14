# GoogleTest registration (discovery, the clang-cl opt-out and its add_test
# fallback) lives in the hub: third_party/ANTfrastructure/cmake/GTestDiscovery.cmake.
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

# Kept under its old name so the Test/*/CMakeLists.txt call sites stay as they
# are; no WORKING_DIRECTORY on purpose (the module header says why).
function(kataglyphis_configure_gtest_discovery test_target)
  kataglyphis_register_gtest_target(${test_target})
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

  # Test suites intentionally suppress their own warnings to keep signal focused
  # on library code compiled through the main targets.
  if(MSVC)
    target_compile_options(${target_name} PRIVATE /w)
  else()
    target_compile_options(${target_name} PRIVATE -w)
  endif()
endfunction()

function(kataglyphis_link_rust_target_if_enabled target_name)
  if(RUST_FEATURES)
    target_link_libraries(${target_name} PUBLIC rusty_code)
  endif()
endfunction()
