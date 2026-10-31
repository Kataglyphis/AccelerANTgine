include_guard(GLOBAL)

function(
  accelerantgine_demo_default_device
  variant
  system_name
  out)
  if(variant STREQUAL "cpu")
    set(_device cpu)
  elseif(variant STREQUAL "nvidia")
    set(_device cuda)
  elseif(variant STREQUAL "amd" AND system_name STREQUAL "Linux")
    set(_device migraphx)
  elseif(variant STREQUAL "amd" AND system_name STREQUAL "Windows")
    set(_device directml)
  else()
    message(FATAL_ERROR "No demo device for ${variant} on ${system_name}")
  endif()
  set(${out}
      "${_device}"
      PARENT_SCOPE)
endfunction()

function(
  accelerantgine_configure_demo_device
  target
  variant
  system_name)
  accelerantgine_demo_default_device("${variant}" "${system_name}" _device)
  target_compile_definitions(${target} PRIVATE "KATAGLYPHIS_DEMO_DEFAULT_DEVICE=\"${_device}\"")
endfunction()

function(
  accelerantgine_find_windows_ort_file
  root
  name
  out)
  set(_selected "")
  foreach(_directory lib bin)
    if(EXISTS "${root}/${_directory}/${name}" AND NOT IS_DIRECTORY "${root}/${_directory}/${name}")
      set(_selected "${root}/${_directory}/${name}")
    endif()
  endforeach()
  set(${out}
      "${_selected}"
      PARENT_SCOPE)
endfunction()

function(
  accelerantgine_validate_ort_package_variant
  variant
  system_name
  system_processor
  top_level)
  if(NOT
     variant
     MATCHES
     "^(cpu|nvidia|amd)$")
    message(FATAL_ERROR "KATAGLYPHIS_ORT_VARIANT must be cpu, nvidia or amd")
  endif()
  if(variant STREQUAL "cpu")
    return()
  endif()
  if(NOT top_level)
    message(FATAL_ERROR "GPU package variants require a top-level build")
  endif()
  string(TOLOWER "${system_processor}" _gpu_arch)
  if(system_name STREQUAL "Windows")
    if(NOT
       _gpu_arch
       MATCHES
       "^(x86_64|amd64|x64)$")
      message(FATAL_ERROR "Windows GPU packages require x64")
    endif()
    return()
  endif()
  if(NOT
     system_name
     STREQUAL
     "Linux")
    message(FATAL_ERROR "GPU package variants require Linux or Windows")
  endif()
  if(NOT
     _gpu_arch
     MATCHES
     "^(x86_64|amd64|x64|aarch64|arm64)$")
    message(FATAL_ERROR "GPU package variants do not support Linux ${system_processor}")
  endif()
  if(variant STREQUAL "amd" AND _gpu_arch MATCHES "^(aarch64|arm64)$")
    message(FATAL_ERROR "Linux arm64 ROCm packages are not supported by this build matrix")
  endif()
endfunction()

function(accelerantgine_require_gpu_packaging_hub hub_dir out_helper)
  set(_helper "${hub_dir}/linux/scripts/06-packaging/ort-runtime-bundle.sh")
  set(_cpack "${hub_dir}/cmake/CPackCommon.cmake")
  set(_appimage_verifier "${hub_dir}/linux/scripts/06-packaging/verify-ort-appimage-payload.sh")
  set(_wheel_verifier "${hub_dir}/linux/scripts/06-packaging/stage-ort-wheel-licenses.py")
  if(NOT EXISTS "${_helper}"
     OR NOT EXISTS "${_cpack}"
     OR NOT EXISTS "${_appimage_verifier}"
     OR NOT EXISTS "${_wheel_verifier}")
    message(FATAL_ERROR "GPU packaging needs ANTfrastructure's ORT staging and external-runtime closure APIs")
  endif()
  file(READ "${_helper}" _helper_source)
  if(NOT
     _helper_source
     MATCHES
     "ort_host_runtime_needed"
     OR NOT
        _helper_source
        MATCHES
        "ort_assert_no_bundled_host_runtime")
    message(FATAL_ERROR "GPU packaging needs ANTfrastructure's host-runtime dependency and exclusion checks")
  endif()
  file(READ "${_cpack}" _cpack_source)
  file(READ "${_wheel_verifier}" _wheel_source)
  if(NOT
     _cpack_source
     MATCHES
     "EXTERNAL_LIBRARY_PATH"
     OR NOT
        _cpack_source
        MATCHES
        "NO_DEFAULT_SYSTEM"
     OR NOT
        _cpack_source
        MATCHES
        "PRESERVE_ORT_IN_APPIMAGE"
     OR NOT
        _wheel_source
        MATCHES
        "--require-unstripped")
    message(FATAL_ERROR "GPU packaging needs ANTfrastructure's ORT staging and external-runtime closure APIs")
  endif()
  set(${out_helper}
      "${_helper}"
      PARENT_SCOPE)
endfunction()

function(
  accelerantgine_gpu_host_dependencies
  helper
  provider
  kind
  out_sonames)
  execute_process(
    COMMAND bash -c [=[set -e; source "$1"; ort_host_runtime_needed "$2" "$3"]=] _ "${helper}" "${provider}" "${kind}"
    RESULT_VARIABLE _status
    OUTPUT_VARIABLE _needed
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(NOT
     _status
     STREQUAL
     "0"
     OR _needed STREQUAL "")
    message(FATAL_ERROR "Cannot identify ${kind} provider host-runtime dependencies")
  endif()
  string(
    REPLACE "\n"
            ";"
            _sonames
            "${_needed}")
  foreach(_soname IN LISTS _sonames)
    if(NOT
       _soname
       MATCHES
       "^[A-Za-z0-9._+-]+$")
      message(FATAL_ERROR "Invalid host-runtime dependency: ${_soname}")
    endif()
  endforeach()
  set(${out_sonames}
      "${_sonames}"
      PARENT_SCOPE)
endfunction()

function(accelerantgine_install_gpu_host_runtime_guard helper kind)
  install(
    CODE "set(_pkg \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\")
execute_process(COMMAND bash -c [=[set -e; source \"$1\"; ort_assert_no_bundled_host_runtime \"$2\" \"$3\"]=] _ \"${helper}\" \"\${_pkg}\" \"${kind}\" COMMAND_ERROR_IS_FATAL ANY)"
  )
endfunction()
