include(GoogleTest)

# all testing related stuff
set(WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../)

# update current positions
set(PROJECT_SRC_DIR ${WORKING_DIRECTORY}Src/)
set(PROJECT_INCLUDE_DIR ${WORKING_DIRECTORY}Src/)
set(EXTERNAL_LIB_SRC_DIR ${WORKING_DIRECTORY}third_party/)

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
kataglyphis_use_text_contract_model(${COMMIT_TEST_SUITE})

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
  add_test(NAME Cli.ChatEndsBeforeAStopString
           COMMAND $<TARGET_FILE:${PROJECT_NAME}_cli> --chat_model "${CMAKE_BINARY_DIR}/test-models/tiny-genai"
                   --prompt abc --max_new_tokens 4 --stop zz,fg)
  set_tests_properties(Cli.ChatEndsBeforeAStopString PROPERTIES PASS_REGULAR_EXPRESSION "^de\n4 tokens, ")
  add_test(NAME Cli.ChatPassesTheSamplingFlags
           COMMAND $<TARGET_FILE:${PROJECT_NAME}_cli> --chat_model "${CMAKE_BINARY_DIR}/test-models/tiny-genai"
                   --prompt abc --max_new_tokens 4 --temperature 0.000001 --seed 7)
  set_tests_properties(Cli.ChatPassesTheSamplingFlags PROPERTIES PASS_REGULAR_EXPRESSION "^defg\n4 tokens, ")
  add_test(NAME Cli.ChatFollowsAJsonSchema
           COMMAND $<TARGET_FILE:${PROJECT_NAME}_cli> --chat_model "${CMAKE_BINARY_DIR}/test-models/tiny-genai"
                   --prompt abc --max_new_tokens 32 --json_schema "${KATAGLYPHIS_TINY_JSON_SCHEMA}")
  # The Windows chain's GenAI has no llguidance, so the CLI must name that instead of answering.
  if(WIN32)
    set_tests_properties(Cli.ChatFollowsAJsonSchema PROPERTIES PASS_REGULAR_EXPRESSION "no JSON schema support")
  else()
    set_tests_properties(Cli.ChatFollowsAJsonSchema PROPERTIES PASS_REGULAR_EXPRESSION "^\\{\"a\":\"#\\$%\"\\}\n")
  endif()
endif()

# The demo's command line: every mode's refusal path, none of which needs a model.
if(TARGET ${PROJECT_NAME}_demo)
  set(_demo_missing_model "${CMAKE_BINARY_DIR}/no-such-model.onnx")
  function(kataglyphis_add_demo_test name pass)
    add_test(NAME Demo.${name} COMMAND $<TARGET_FILE:${PROJECT_NAME}_demo> ${ARGN})
    # A matched message ignores the exit status, so a sanitizer report after it must still fail.
    set_tests_properties(
      Demo.${name}
      PROPERTIES PASS_REGULAR_EXPRESSION
                 "${pass}"
                 FAIL_REGULAR_EXPRESSION
                 "Sanitizer|runtime error")
  endfunction()
  kataglyphis_add_demo_test(HelpListsEveryMode "--detector-repeat-output <json>" --help)
  # Its model path and output layout come from its config: the shipped one, or the one --config names.
  set(_demo_config "${CMAKE_CURRENT_BINARY_DIR}/demo-config-test.toml")
  file(WRITE "${_demo_config}" "[model]\nmodel_path = \"config-named.onnx\"\noutput_layout = \"auto\"\n")
  kataglyphis_add_demo_test(
    ReadsTheModelAndLayoutFromItsConfig
    "config-named\\.onnx\"?\nOutput layout: auto\n"
    --config
    "${_demo_config}"
    --yolo-only
    --device
    cpu)
  kataglyphis_add_demo_test(
    DefaultsToTheShippedConfig
    "deim_dfine_n_coco\\.onnx\"?\nOutput layout: xyxy_score_class\n"
    --yolo-only
    --device
    cpu)
  set(_demo_bad_config "${CMAKE_CURRENT_BINARY_DIR}/demo-bad-layout-test.toml")
  file(WRITE "${_demo_bad_config}" "[model]\nmodel_path = \"m.onnx\"\noutput_layout = \"rows\"\n")
  kataglyphis_add_demo_test(
    RefusesAnUnknownLayout
    "Invalid output_layout: rows"
    --config
    "${_demo_bad_config}"
    --yolo-only)
  kataglyphis_add_demo_test(GStreamerExampleEnds "GStreamer example completed!" --gstreamer-only)
  set_tests_properties(Demo.GStreamerExampleEnds PROPERTIES TIMEOUT 120)
  kataglyphis_add_demo_test(
    OnnxExampleReportsAMissingModel
    "ONNX inference example failed!"
    --model
    "${_demo_missing_model}"
    --onnx-only)
  kataglyphis_add_demo_test(
    YoloExampleReportsAMissingModel
    "YOLO detection example failed!"
    --model
    "${_demo_missing_model}"
    --yolo-only)
  kataglyphis_add_demo_test(
    VideoExampleReportsAMissingFile
    "Video detection example failed!"
    --model
    "${_demo_missing_model}"
    --video-only)
  kataglyphis_add_demo_test(
    VideoCheckReportsAMissingModel
    "Video detector initialization failed"
    --model
    "${_demo_missing_model}"
    --video-check)
  kataglyphis_add_demo_test(
    UnknownDeviceIsRefused
    "Unknown device: quantum"
    --device
    quantum)
  kataglyphis_add_demo_test(
    MalformedDeviceIndexIsRefused
    "Invalid device index: 3x"
    --device-id
    3x)
  kataglyphis_add_demo_test(UnknownOptionIsRefused "Unknown or incomplete option: --frobnicate" --frobnicate)
  kataglyphis_add_demo_test(
    ImageDetectionNeedsOutputAndProfile
    "requires an image, output and profile"
    --detector-image
    image.jpg)
  kataglyphis_add_demo_test(
    ImageDetectionRefusesOtherModes
    "requires an image, output and profile"
    --detector-image
    image.jpg
    --detector-output
    out.json
    --profile
    profile
    --onnx-only)
  kataglyphis_add_demo_test(
    ImageDetectionReportsAMissingImage
    "Could not open the detector image"
    --detector-image
    "${CMAKE_BINARY_DIR}/no-such-image.jpg"
    --detector-output
    out.json
    --profile
    profile)
endif()
