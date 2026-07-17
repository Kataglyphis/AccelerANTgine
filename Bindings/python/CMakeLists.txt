# Python bindings for KataglyphisCppInference (nanobind).
# Only entered when KATAGLYPHIS_BUILD_PYTHON_BINDINGS is ON — nanobind and
# find_package(Python) are set up in ExternalLib/CMakeLists.txt.

option(KATAGLYPHIS_PYTHON_STUBS "Generate .pyi stubs for the Python bindings" ON)

nanobind_add_module(kataglyphis_python NB_STATIC kataglyphis_bindings.cpp)

set_target_properties(
  kataglyphis_python
  PROPERTIES OUTPUT_NAME "_core"
             # The binding TU imports the project's C++ modules (.ixx); the
             # global scan switch is OFF for clang-cl, so opt in per-target
             # exactly like the CLI target does.
             CXX_SCAN_FOR_MODULES ON
             # On ELF platforms the extension must find the core shared
             # library sitting next to it inside the package directory.
             BUILD_RPATH "$ORIGIN"
             INSTALL_RPATH "$ORIGIN")

target_compile_features(kataglyphis_python PRIVATE cxx_std_23)

# NOTE: deliberately no myproject_warnings here — nanobind's headers are not
# warning-clean under the project's warning set. myproject_options flags still
# arrive transitively via KataglyphisCppInference's PUBLIC link, which keeps
# the BMI-relevant flags (/EHs, sanitizers) consistent with the imported BMIs.
target_link_libraries(kataglyphis_python PRIVATE KataglyphisCppInference)

# --- Stage an importable package into <build>/python/kataglyphis_inference ---
set(KATAGLYPHIS_PY_STAGE_DIR "${CMAKE_BINARY_DIR}/python/kataglyphis_inference")

add_custom_command(
  TARGET kataglyphis_python
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${KATAGLYPHIS_PY_STAGE_DIR}"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:kataglyphis_python>"
          "${KATAGLYPHIS_PY_STAGE_DIR}/"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/kataglyphis_inference/__init__.py" "${KATAGLYPHIS_PY_STAGE_DIR}/"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:KataglyphisCppInference>"
          "${KATAGLYPHIS_PY_STAGE_DIR}/"
  COMMENT "Staging Python package into ${KATAGLYPHIS_PY_STAGE_DIR}")

# --- Type stubs (.pyi) -------------------------------------------------------
if(KATAGLYPHIS_PYTHON_STUBS)
  nanobind_add_stub(
    kataglyphis_python_stub
    MODULE kataglyphis_inference._core
    OUTPUT "${KATAGLYPHIS_PY_STAGE_DIR}/_core.pyi"
    PYTHON_PATH "${CMAKE_BINARY_DIR}/python"
    MARKER_FILE "${KATAGLYPHIS_PY_STAGE_DIR}/py.typed"
    DEPENDS kataglyphis_python)
endif()

# --- Wheel install rules (scikit-build-core selects the python_bindings
# component; the project's regular install tree is untouched) ----------------
install(
  TARGETS kataglyphis_python
  LIBRARY DESTINATION kataglyphis_inference COMPONENT python_bindings
  RUNTIME DESTINATION kataglyphis_inference COMPONENT python_bindings)
install(FILES kataglyphis_inference/__init__.py
        DESTINATION kataglyphis_inference
        COMPONENT python_bindings)
install(
  TARGETS KataglyphisCppInference
  RUNTIME DESTINATION kataglyphis_inference COMPONENT python_bindings
  LIBRARY DESTINATION kataglyphis_inference COMPONENT python_bindings
  ARCHIVE DESTINATION lib COMPONENT python_native_dev)
if(KATAGLYPHIS_PYTHON_STUBS)
  install(FILES "${KATAGLYPHIS_PY_STAGE_DIR}/_core.pyi" "${KATAGLYPHIS_PY_STAGE_DIR}/py.typed"
          DESTINATION kataglyphis_inference
          COMPONENT python_bindings)
endif()

# --- CTest hook (only active in configurations that enable testing) ----------
if(BUILD_TESTING)
  execute_process(
    COMMAND "${Python_EXECUTABLE}" -c "import pytest"
    RESULT_VARIABLE _pytest_missing
    OUTPUT_QUIET ERROR_QUIET)
  if(_pytest_missing EQUAL 0)
    add_test(NAME python_bindings COMMAND "${Python_EXECUTABLE}" -m pytest
                                          "${CMAKE_SOURCE_DIR}/Test/python" -v)
    set_tests_properties(python_bindings PROPERTIES ENVIRONMENT
                                                    "PYTHONPATH=${CMAKE_BINARY_DIR}/python")
  else()
    message(STATUS "pytest not available in ${Python_EXECUTABLE} — skipping python_bindings ctest registration")
  endif()
endif()
