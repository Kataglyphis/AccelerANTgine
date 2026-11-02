# The `golden` ctest label: the real model on ModelANT's photo against a recorded run, plus the demo's ORT knobs.
include(GoogleTest)
include(${CMAKE_CURRENT_LIST_DIR}/../cmake/CommonTestBuild.cmake)

# The model's file name lives in models.lock alone; the hub's fetch-data-lock.py puts it beside the lock.
file(STRINGS "${PROJECT_SOURCE_DIR}/models/models.lock" _golden_model_row REGEX "^[0-9a-f]+ +[^ ]+\\.onnx ")
list(LENGTH _golden_model_row _golden_model_rows)
if(NOT
   _golden_model_rows
   EQUAL
   1)
  message(FATAL_ERROR "models/models.lock must lock exactly one .onnx model, found ${_golden_model_rows}")
endif()
string(
  REGEX
  REPLACE "^[0-9a-f]+ +([^ ]+\\.onnx) .*$"
          "\\1"
          _golden_model_name
          "${_golden_model_row}")
set(_golden_model "${PROJECT_SOURCE_DIR}/models/${_golden_model_name}")
set(_golden_image "${PROJECT_SOURCE_DIR}/third_party/ModelANT/contracts/fixtures/two_cats.jpg")

add_executable(goldenTestSuite golden_detector_test.cpp)
kataglyphis_configure_common_test_target(goldenTestSuite "/../Resources/" "/../Src/")
kataglyphis_configure_library_test_target(goldenTestSuite)
target_compile_definitions(
  goldenTestSuite PRIVATE KATAGLYPHIS_GOLDEN_MODEL="${_golden_model}" KATAGLYPHIS_GOLDEN_IMAGE="${_golden_image}"
                          KATAGLYPHIS_GOLDEN_JSON="${CMAKE_CURRENT_SOURCE_DIR}/two_cats_cpu.json")
target_link_libraries(
  goldenTestSuite
  PRIVATE myproject_options
          gtest
          gtest_main
          ${CMAKE_DL_LIBS}
          ${PROJECT_NAME})
gtest_discover_tests(
  goldenTestSuite
  DISCOVERY_TIMEOUT
  300
  DISCOVERY_MODE
  PRE_TEST
  PROPERTIES LABELS golden)

if(TARGET ${PROJECT_NAME}_demo)
  set(_golden_config "${CMAKE_CURRENT_BINARY_DIR}/golden_threads.toml")
  file(WRITE "${_golden_config}" "[model]\nmodel_path = \"${_golden_model}\"\nintra_op_threads = 2\n")
  add_test(NAME Golden.DemoThreadsFlagReachesTheSession COMMAND $<TARGET_FILE:${PROJECT_NAME}_demo> --model
                                                                "${_golden_model}" --yolo-only --threads 3)
  add_test(NAME Golden.DemoConfigThreadsReachTheSession COMMAND $<TARGET_FILE:${PROJECT_NAME}_demo> --config
                                                                "${_golden_config}" --yolo-only)
  set_tests_properties(
    Golden.DemoThreadsFlagReachesTheSession
    PROPERTIES LABELS
               golden
               PASS_REGULAR_EXPRESSION
               "ORT intra-op threads: 3\n")
  set_tests_properties(
    Golden.DemoConfigThreadsReachTheSession
    PROPERTIES LABELS
               golden
               PASS_REGULAR_EXPRESSION
               "ORT intra-op threads: 2\n")
  add_test(NAME Golden.DemoDetectorLatencyPrintsFigures
           COMMAND $<TARGET_FILE:${PROJECT_NAME}_demo> --model "${_golden_model}" --detector-image "${_golden_image}"
                   --detector-latency-runs 2 --device cpu)
  set_tests_properties(
    Golden.DemoDetectorLatencyPrintsFigures
    PROPERTIES LABELS
               golden
               PASS_REGULAR_EXPRESSION
               "\\{\"p50_ms\":[0-9.e+-]+,\"p95_ms\":[0-9.e+-]+\\}")
  # The hub's verify_ort_profile.py must find XNNPACK operators in both runs of the demo's profiled session.
  set(_golden_evidence "${CMAKE_CURRENT_BINARY_DIR}/xnnpack-evidence")
  add_test(
    NAME Golden.XnnpackProfileNamesTheProvider
    COMMAND
      sh -c "rm -rf -- \"$1\" && exec bash \"$2\" \"$3\" \"$4\" xnnpack \"$1\"" golden "${_golden_evidence}"
      "${PROJECT_SOURCE_DIR}/scripts/linux/check-gpu-detector-parity.sh" $<TARGET_FILE:${PROJECT_NAME}_demo>
      "${_golden_model}")
  set_tests_properties(Golden.XnnpackProfileNamesTheProvider PROPERTIES LABELS golden)
endif()
