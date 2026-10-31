include(GoogleTest)

# all testing related stuff
set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}third_party/)

include(${PROJECT_SRC_DIR}cmake/filters/SetProjectFilters.cmake)
include(${WORKING_DIRECTORY}Test/cmake/CommonTestBuild.cmake)

set(COMMIT_TEST_SUITE commitTestSuite)
option(KATAGLYPHIS_TEST_MIGRAPHX "Include the real MIGraphX hardware regression in the commit suite" OFF)

file(
  GLOB_RECURSE
  KataglyphisCppProject_COMMIT_TEST_FILTER
  CONFIGURE_DEPENDS
  "*.cpp")

message("Commit test filter is: ${KataglyphisCppProject_COMMIT_TEST_FILTER}")

add_executable(${COMMIT_TEST_SUITE})

set(_commit_resource_path "/../../../Resources/")
set(_commit_include_path "/../../../Src/")
if(NOT MSVC)

else()
  set(_commit_resource_path "/../Resources/")
  set(_commit_include_path "/../Src/")
endif()

kataglyphis_configure_common_test_target(${COMMIT_TEST_SUITE} "${_commit_resource_path}" "${_commit_include_path}")
kataglyphis_configure_library_test_target(${COMMIT_TEST_SUITE})

target_sources(${COMMIT_TEST_SUITE} PRIVATE ${KataglyphisCppProject_COMMIT_TEST_FILTER})
if(KATAGLYPHIS_TEST_MIGRAPHX)
  target_compile_definitions(${COMMIT_TEST_SUITE} PRIVATE KATAGLYPHIS_TEST_MIGRAPHX=1)
endif()

target_link_libraries(
  ${COMMIT_TEST_SUITE}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE gtest
          gtest_main
          GSL
          spdlog
          ${PROJECT_NAME})

kataglyphis_use_tiny_genai_model(${COMMIT_TEST_SUITE})

kataglyphis_configure_gtest_discovery(${COMMIT_TEST_SUITE})

# The CLI's chat mode on the tiny model: the reply first, then the speed figures.
if(TARGET ${PROJECT_NAME}_cli)
  add_test(NAME Cli.ChatAnswersThePromptOnStdout
           COMMAND $<TARGET_FILE:${PROJECT_NAME}_cli> --chat_model "${CMAKE_BINARY_DIR}/test-models/tiny-genai"
                   --prompt abc --max_new_tokens 4)
  set_tests_properties(Cli.ChatAnswersThePromptOnStdout PROPERTIES PASS_REGULAR_EXPRESSION "^defg\n4 tokens, ")
  add_test(NAME Cli.ChatWithoutAPromptFails COMMAND $<TARGET_FILE:${PROJECT_NAME}_cli> --chat_model
                                                    "${CMAKE_BINARY_DIR}/test-models/tiny-genai")
  set_tests_properties(Cli.ChatWithoutAPromptFails PROPERTIES WILL_FAIL TRUE)
endif()
