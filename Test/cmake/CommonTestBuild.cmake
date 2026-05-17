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

function(kataglyphis_configure_gtest_discovery test_target)
  if(NOT DEFINED KATAGLYPHIS_ENABLE_GTEST_DISCOVERY)
    set(KATAGLYPHIS_ENABLE_GTEST_DISCOVERY ON)
  endif()

  # clang-cl ASan/UBSan executables can fail during gtest discovery on Windows
  # with loader errors (0xc0000135). Fall back to a plain add_test registration.
  if(WIN32 AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)
    set(KATAGLYPHIS_ENABLE_GTEST_DISCOVERY OFF)
  endif()

  if(KATAGLYPHIS_ENABLE_GTEST_DISCOVERY)
    message(STATUS "Enabling gtest_discover_tests for ${test_target}.")
    # On Windows ASan builds, running test executables during build can fail due
    # to runtime loader path issues. PRE_TEST discovery defers this to ctest.
    gtest_discover_tests(
      ${test_target}
      DISCOVERY_TIMEOUT
      300
      DISCOVERY_MODE
      PRE_TEST)
  else()
    message(STATUS "KATAGLYPHIS_ENABLE_GTEST_DISCOVERY is OFF - using add_test fallback for ${test_target}.")
    add_test(NAME ${test_target} COMMAND $<TARGET_FILE:${test_target}>)
    if(WIN32)
      get_filename_component(_kataglyphis_compiler_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
      set_tests_properties(
        ${test_target}
        PROPERTIES WORKING_DIRECTORY "$<TARGET_FILE_DIR:${test_target}>"
                   ENVIRONMENT "PATH=$<TARGET_FILE_DIR:${test_target}>;${CMAKE_BINARY_DIR}/bin;${CMAKE_BINARY_DIR}/lib;${_kataglyphis_compiler_dir};$ENV{PATH}")
    endif()
  endif()
endfunction()

function(kataglyphis_configure_common_test_target target_name resource_path include_path)
  if(RUST_FEATURES)
    target_compile_definitions(${target_name} PRIVATE USE_RUST=1)
  else()
    target_compile_definitions(${target_name} PRIVATE USE_RUST=0)
  endif()

  target_compile_definitions(${target_name}
                             PRIVATE RELATIVE_RESOURCE_PATH="${resource_path}" RELATIVE_INCLUDE_PATH="${include_path}")

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
