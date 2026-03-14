# # we depend on vulkan
# find_package(Vulkan REQUIRED)
# # configure vulkan version
# set(VULKAN_VERSION_MAJOR 1)
# set(VULKAN_VERSION_MINOR 3)
find_package(Threads REQUIRED)

# # we depend on OpenGL
# find_package(OpenGL REQUIRED COMPONENTS OpenGL)
# # configure OpenGL version
# set(OPENGL_VERSION_MAJOR 4)
# set(OPENGL_VERSION_MINOR 6)
# set(OpenGL_GL_PREFERENCE GLVND)

# GStreamer dependencies
set(GSTREAMER_ROOT "/opt/gstreamer" CACHE PATH "GStreamer installation root")

if(EXISTS "${GSTREAMER_ROOT}")
    set(PKG_CONFIG_PATH "${GSTREAMER_ROOT}/lib/aarch64-linux-gnu/pkgconfig:${GSTREAMER_ROOT}/lib/pkgconfig:${PKG_CONFIG_PATH}"
        CACHE INTERNAL "GStreamer pkg-config path")
    set(CMAKE_PREFIX_PATH "${GSTREAMER_ROOT};${CMAKE_PREFIX_PATH}")
    
    set(ENV{PKG_CONFIG_PATH} "${GSTREAMER_ROOT}/lib/aarch64-linux-gnu/pkgconfig:${GSTREAMER_ROOT}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
endif()

find_package(PkgConfig REQUIRED)

pkg_check_modules(GSTREAMER REQUIRED 
    gstreamer-1.0>=1.24
    gstreamer-app-1.0>=1.24
    gstreamer-video-1.0>=1.24
    gstreamer-analytics-1.0>=1.24
)

pkg_check_modules(GLIB REQUIRED glib-2.0>=2.70)

# ONNX Runtime dependencies
# Check multiple possible installation locations:
# 1. Container build output: /usr/local/lib/onnxruntime-cpu (from ContainerHub scripts)
# 2. Source installation: /opt/onnxruntime
# 3. System installation: /usr

set(ONNXRUNTIME_SEARCH_PATHS
    "/usr/local/lib/onnxruntime-cpu"
    "/opt/onnxruntime"
    "/usr"
    "/usr/local"
)

set(ONNXRUNTIME_ROOT "" CACHE PATH "ONNX Runtime installation root")

if(ONNXRUNTIME_ROOT)
    list(INSERT ONNXRUNTIME_SEARCH_PATHS 0 "${ONNXRUNTIME_ROOT}")
endif()

# Try to find ONNX Runtime in each search path
set(ONNXRUNTIME_FOUND FALSE)

foreach(_search_path ${ONNXRUNTIME_SEARCH_PATHS})
    if(EXISTS "${_search_path}")
        # Check for library
        find_library(_ONNXRUNTIME_LIB
            NAMES onnxruntime libonnxruntime
            PATHS 
                "${_search_path}/lib"
                "${_search_path}/lib64"
                "${_search_path}/lib/aarch64-linux-gnu"
                "${_search_path}/lib/x86_64-linux-gnu"
            NO_DEFAULT_PATH
        )
        
        # Check for headers
        find_path(_ONNXRUNTIME_INCLUDE_DIR
            NAMES onnxruntime_cxx_api.h
            PATHS
                "${_search_path}/include"
                "${_search_path}/include/onnxruntime"
                "${_search_path}/include/onnxruntime/core/session"
            NO_DEFAULT_PATH
        )
        
        # Also check for headers in nested structure
        if(NOT _ONNXRUNTIME_INCLUDE_DIR)
            find_path(_ONNXRUNTIME_INCLUDE_DIR
                NAMES onnxruntime_c_api.h
                PATHS
                    "${_search_path}/include"
                    "${_search_path}/include/onnxruntime"
                NO_DEFAULT_PATH
            )
        endif()
        
        if(_ONNXRUNTIME_LIB AND _ONNXRUNTIME_INCLUDE_DIR)
            set(ONNXRUNTIME_FOUND TRUE)
            set(ONNXRUNTIME_LIBRARY "${_ONNXRUNTIME_LIB}")
            set(ONNXRUNTIME_INCLUDE_DIR "${_ONNXRUNTIME_INCLUDE_DIR}")
            set(ONNXRUNTIME_ROOT "${_search_path}")
            message(STATUS "Found ONNX Runtime at: ${_search_path}")
            message(STATUS "  Library: ${_ONNXRUNTIME_LIB}")
            message(STATUS "  Headers: ${_ONNXRUNTIME_INCLUDE_DIR}")
            break()
        endif()
        
        # Clear cache for next iteration
        unset(_ONNXRUNTIME_LIB CACHE)
        unset(_ONNXRUNTIME_INCLUDE_DIR CACHE)
    endif()
endforeach()

# Fallback to pkg-config
if(NOT ONNXRUNTIME_FOUND)
    pkg_check_modules(_ONNXRUNTIME_PKG libonnxruntime onnxruntime)
    if(_ONNXRUNTIME_PKG_FOUND)
        set(ONNXRUNTIME_FOUND TRUE)
        set(ONNXRUNTIME_LIBRARY "${_ONNXRUNTIME_PKG_LINK_LIBRARIES}")
        set(ONNXRUNTIME_INCLUDE_DIR "${_ONNXRUNTIME_PKG_INCLUDE_DIRS}")
        message(STATUS "Found ONNX Runtime via pkg-config")
    endif()
endif()

if(NOT ONNXRUNTIME_FOUND)
    message(WARNING "ONNX Runtime not found. Install via:")
    message(WARNING "  - Container: /usr/local/lib/onnxruntime-cpu")
    message(WARNING "  - Source: /opt/onnxruntime")
    message(WARNING "  - Package: apt install libonnxruntime-dev")
endif()

# Create imported targets for GStreamer
if(GSTREAMER_FOUND)
    add_library(gstreamer::gstreamer INTERFACE IMPORTED)
    target_include_directories(gstreamer::gstreamer INTERFACE ${GSTREAMER_INCLUDE_DIRS})
    target_link_directories(gstreamer::gstreamer INTERFACE ${GSTREAMER_LIBRARY_DIRS})
    target_link_libraries(gstreamer::gstreamer INTERFACE ${GSTREAMER_LIBRARIES})
    
    add_library(gstreamer::app INTERFACE IMPORTED)
    target_include_directories(gstreamer::app INTERFACE ${GSTREAMER_INCLUDE_DIRS})
    target_link_directories(gstreamer::app INTERFACE ${GSTREAMER_LIBRARY_DIRS})
    target_link_libraries(gstreamer::app INTERFACE gstapp-1.0)
    
    add_library(gstreamer::video INTERFACE IMPORTED)
    target_include_directories(gstreamer::video INTERFACE ${GSTREAMER_INCLUDE_DIRS})
    target_link_directories(gstreamer::video INTERFACE ${GSTREAMER_LIBRARY_DIRS})
    target_link_libraries(gstreamer::video INTERFACE gstvideo-1.0)
    
    add_library(gstreamer::analytics INTERFACE IMPORTED)
    target_include_directories(gstreamer::analytics INTERFACE ${GSTREAMER_INCLUDE_DIRS})
    target_link_directories(gstreamer::analytics INTERFACE ${GSTREAMER_LIBRARY_DIRS})
    target_link_libraries(gstreamer::analytics INTERFACE gstanalytics-1.0)
endif()

# Create imported target for ONNX Runtime
if(ONNXRUNTIME_FOUND AND ONNXRUNTIME_LIBRARY)
    add_library(onnxruntime::onnxruntime SHARED IMPORTED)
    set_target_properties(onnxruntime::onnxruntime PROPERTIES
        IMPORTED_LOCATION "${ONNXRUNTIME_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${ONNXRUNTIME_INCLUDE_DIR}"
    )
    # Add additional include directories for nested header structure
    if(EXISTS "${ONNXRUNTIME_ROOT}/include/onnxruntime/core/session")
        target_include_directories(onnxruntime::onnxruntime INTERFACE
            "${ONNXRUNTIME_ROOT}/include/onnxruntime/core/session"
        )
    endif()
    if(EXISTS "${ONNXRUNTIME_ROOT}/include/onnxruntime/core/providers/cpu")
        target_include_directories(onnxruntime::onnxruntime INTERFACE
            "${ONNXRUNTIME_ROOT}/include/onnxruntime/core/providers/cpu"
        )
    endif()
    message(STATUS "ONNX Runtime imported target created successfully")
endif()
