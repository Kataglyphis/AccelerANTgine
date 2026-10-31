set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/")

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_MODULES "*.ixx")
# Programs with their own main(): the library must carry none, or every embedder links a dead one.
list(
  REMOVE_ITEM
  KataglyphisCppProject_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/cli_main.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/inference_demo.cpp")

# ONNXRUNTIME_FOUND comes from SystemLibDependencies.cmake, which must run first.
if(NOT ONNXRUNTIME_FOUND)
  message(STATUS "Excluding ONNX inference sources (ONNX Runtime not found)")
  list(
    REMOVE_ITEM
    KataglyphisCppProject_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/onnx_inference_engine.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/yolo_detector.cpp")
  list(
    REMOVE_ITEM
    KataglyphisCppProject_MODULES
    "${CMAKE_CURRENT_SOURCE_DIR}/onnx_inference_engine.ixx"
    "${CMAKE_CURRENT_SOURCE_DIR}/yolo_detector.ixx")
endif()

set(KataglyphisCppProjectConfig_MODULE_IN "${CMAKE_CURRENT_SOURCE_DIR}/KataglyphisCppProjectConfig.ixx.in")
set(KataglyphisCppProjectConfig_MODULE_OUT "${CMAKE_CURRENT_BINARY_DIR}/KataglyphisCppProjectConfig.ixx")
configure_file(${KataglyphisCppProjectConfig_MODULE_IN} ${KataglyphisCppProjectConfig_MODULE_OUT} @ONLY)
list(APPEND KataglyphisCppProject_MODULES ${KataglyphisCppProjectConfig_MODULE_OUT})

corrosion_import_crate(MANIFEST_PATH rusty_code/Cargo.toml)

include(CorrosionToolchain)
kataglyphis_configure_corrosion_target(rusty_code ADDRESS_SANITIZER ${myproject_ENABLE_SANITIZER_ADDRESS})

corrosion_add_cxxbridge(
  rusty_bridge
  CRATE
  rusty_code
  FILES
  lib.rs)

# add the executable
add_library(${PROJECT_NAME} SHARED)
set_target_properties(
  ${PROJECT_NAME}
  PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
             LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
             RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
# Enable module scanning on project targets so CMake can generate dyndep/BMI ordering.
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_SCAN_FOR_MODULES ON)

if(PROJECT_IS_TOP_LEVEL)
  if(MYPROJECT_USE_CPP_MODULES)
    add_executable(${PROJECT_NAME}_cli cli_main.cpp)
    kataglyphis_add_windows_icon(${PROJECT_NAME}_cli "${PROJECT_SOURCE_DIR}/images/faviconNew.ico")
    set_target_properties(${PROJECT_NAME}_cli PROPERTIES OUTPUT_NAME "${PROJECT_NAME}" RUNTIME_OUTPUT_DIRECTORY
                                                                                       "${CMAKE_BINARY_DIR}/bin")
    set_target_properties(${PROJECT_NAME}_cli PROPERTIES CXX_SCAN_FOR_MODULES ON)
    # The demo models/README.md runs; it needs the ONNX modules the library drops without ONNX Runtime.
    if(ONNXRUNTIME_FOUND)
      add_executable(${PROJECT_NAME}_demo inference_demo.cpp)
      accelerantgine_configure_demo_device(${PROJECT_NAME}_demo "${KATAGLYPHIS_ORT_VARIANT}" "${CMAKE_SYSTEM_NAME}")
      kataglyphis_add_windows_icon(${PROJECT_NAME}_demo "${PROJECT_SOURCE_DIR}/images/faviconNew.ico")
      set_target_properties(${PROJECT_NAME}_demo PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
                                                            CXX_SCAN_FOR_MODULES ON)
    endif()
  else()
    message(STATUS "Skipping ${PROJECT_NAME}_cli: requires C++ modules")
  endif()
endif()

target_compile_features(${PROJECT_NAME} PUBLIC cxx_std_23)
if(TARGET ${PROJECT_NAME}_cli)
  target_compile_features(${PROJECT_NAME}_cli PRIVATE cxx_std_23)
endif()
if(TARGET ${PROJECT_NAME}_demo)
  target_compile_features(${PROJECT_NAME}_demo PRIVATE cxx_std_23)
endif()

# Define export macro for building the DLL
target_compile_definitions(${PROJECT_NAME} PRIVATE KATAGLYPHIS_EXPORTS)

# Set symbol visibility
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)

# MSVC deploys one directory deeper than clang-cl, hence the extra ../.
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
         myproject_warnings
         myproject_options
         nlohmann_json_modules
         tomlplusplus_modules
  PRIVATE GSL spdlog::spdlog)

# Link GStreamer and ONNX Runtime if available
if(TARGET PkgConfig::GSTREAMER)
  target_link_libraries(${PROJECT_NAME} PUBLIC PkgConfig::GSTREAMER)
  target_compile_definitions(${PROJECT_NAME} PUBLIC HAS_GSTREAMER_WEBRTC=1)
  message(STATUS "GStreamer linked successfully (with WebRTC support via pkg-config)")
else()
  message(WARNING "GStreamer not found - inference pipeline features disabled")
  target_compile_definitions(${PROJECT_NAME} PUBLIC HAS_GSTREAMER_WEBRTC=0)
endif()

if(TARGET onnxruntime::onnxruntime)
  target_link_libraries(${PROJECT_NAME} PUBLIC onnxruntime::onnxruntime)
  target_compile_definitions(${PROJECT_NAME} PUBLIC HAS_ONNXRUNTIME=1)
  message(STATUS "ONNX Runtime linked successfully")
else()
  message(WARNING "ONNX Runtime not found - ONNX inference features disabled")
  target_compile_definitions(${PROJECT_NAME} PUBLIC HAS_ONNXRUNTIME=0)
endif()

target_link_libraries(${PROJECT_NAME} PUBLIC rusty_code)
target_link_libraries(${PROJECT_NAME} PRIVATE onnxruntime_genai::headers)

if(TARGET ${PROJECT_NAME}_cli)
  target_link_libraries(${PROJECT_NAME}_cli PRIVATE ${PROJECT_NAME} absl::flags_parse)
endif()
if(TARGET ${PROJECT_NAME}_demo)
  target_link_libraries(${PROJECT_NAME}_demo PRIVATE ${PROJECT_NAME})
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
  set_property(
    SOURCE ${KataglyphisCppProject_MODULES}
    APPEND
    PROPERTY COMPILE_OPTIONS "-fno-sanitize=undefined")
endif()
