include_guard(GLOBAL)

# Refuses any ORT without the chain build's embedded source path; it cannot tell two chain builds apart.
function(
  accelerantgine_assert_ort_chain_build
  runtime
  marker
  root)
  # An optional fourth argument names the library in the messages; GenAI's proof passes its own name.
  set(_what "ONNX Runtime")
  if(ARGC GREATER 3)
    set(_what "${ARGV3}")
  endif()
  if(NOT EXISTS "${runtime}")
    message(FATAL_ERROR "${_what}: ${runtime} is missing, so ${root} cannot be proved to be the chain build.")
  endif()
  file(
    STRINGS "${runtime}" _ort_chain_hit
    LIMIT_COUNT 1
    REGEX "${marker}")
  if(NOT _ort_chain_hit)
    message(
      FATAL_ERROR
        "${_what}: ${runtime} is not the family's chain build (no '${marker}' source path in it). A downloaded, distro or vendor build is not allowed."
    )
  endif()
endfunction()

# GenAI's header dir under root, and the chain proof ORT has for the library text_generation.cpp loads at run time.
function(
  accelerantgine_find_chain_genai
  root
  system_name
  out_include_dir)
  unset(_genai_include CACHE)
  find_path(
    _genai_include
    NAMES ort_genai_c.h
    PATHS "${root}/include" "${root}"
    NO_DEFAULT_PATH NO_CACHE)
  if(NOT _genai_include)
    message(
      FATAL_ERROR
        "ONNX Runtime GenAI: no ort_genai_c.h under ${root}. Only the family image's chain build is allowed; nothing else is searched."
    )
  endif()
  if(system_name STREQUAL "Windows")
    find_file(
      _genai_runtime
      NAMES onnxruntime-genai.dll
      PATHS "${root}/bin" "${root}/lib"
      NO_DEFAULT_PATH NO_CACHE)
    set(_genai_marker "temp.onnx-genai-src.")
  else()
    set(_genai_runtime "${root}/lib/libonnxruntime-genai.so")
    set(_genai_marker "/opt/onnxruntime-genai/")
  endif()
  accelerantgine_assert_ort_chain_build(
    "${_genai_runtime}"
    "${_genai_marker}"
    "${root}"
    "ONNX Runtime GenAI")
  set(${out_include_dir}
      "${_genai_include}"
      PARENT_SCOPE)
endfunction()

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
  if(NOT
     _helper_source
     MATCHES
     "ort_amdgpu_ep_dir"
     OR NOT
        _helper_source
        MATCHES
        "ort_assert_plugin_module")
    message(FATAL_ERROR "GPU packaging needs ANTfrastructure's plugin MIGraphX module staging and proof")
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

# The image's plugin MIGraphX module, where the hub's staging helper takes it from.
function(accelerantgine_amdgpu_ep_module helper out_module)
  execute_process(
    COMMAND bash -c [=[set -e; source "$1"; printf '%s/%s' "$(ort_amdgpu_ep_dir)" "${ORT_AMDGPU_EP_MODULE:?}"]=] _
            "${helper}"
    RESULT_VARIABLE _status
    OUTPUT_VARIABLE _module)
  if(NOT
     _status
     STREQUAL
     "0"
     OR NOT EXISTS "${_module}"
     OR IS_DIRECTORY "${_module}")
    message(FATAL_ERROR "amd package requires the image's plugin MIGraphX module, looked for at '${_module}'")
  endif()
  set(${out_module}
      "${_module}"
      PARENT_SCOPE)
endfunction()

# CPack's AppImage step patches every ELF and the hub's wrapper keeps glibc and libonnxruntime* only.
function(accelerantgine_keep_module_in_appimage module_name patchelf_var)
  set(_inner "${${patchelf_var}}")
  if(NOT _inner)
    message(FATAL_ERROR "The AppImage patchelf wrapper must be set before ${module_name} is kept out of it")
  endif()
  set(_wrapper "${PROJECT_BINARY_DIR}/tools/patchelf-keep-plugin-module.sh")
  file(MAKE_DIRECTORY "${PROJECT_BINARY_DIR}/tools")
  file(
    WRITE "${_wrapper}"
    "#!/usr/bin/env bash\nfor arg in \"$@\"; do [[ \"\${arg##*/}\" != \"${module_name}\" ]] || exit 0; done\nexec \"${_inner}\" \"$@\"\n"
  )
  file(
    CHMOD
    "${_wrapper}"
    PERMISSIONS
    OWNER_READ
    OWNER_WRITE
    OWNER_EXECUTE
    GROUP_READ
    GROUP_EXECUTE
    WORLD_READ
    WORLD_EXECUTE)
  set(${patchelf_var}
      "${_wrapper}"
      PARENT_SCOPE)
endfunction()

# The staged module must still be the image's bytes after the closure ran over the tree.
function(accelerantgine_install_plugin_module_proof helper module)
  install(
    CODE "set(_pkg \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\")
execute_process(COMMAND bash -c [=[set -e; source \"$1\"; ort_assert_plugin_module \"$2\"]=] _ \"${helper}\" \"\${_pkg}/${module}\" COMMAND_ERROR_IS_FATAL ANY)"
  )
endfunction()

function(accelerantgine_install_gpu_host_runtime_guard helper kind)
  install(
    CODE "set(_pkg \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\")
execute_process(COMMAND bash -c [=[set -e; source \"$1\"; ort_assert_no_bundled_host_runtime \"$2\" \"$3\"]=] _ \"${helper}\" \"\${_pkg}\" \"${kind}\" COMMAND_ERROR_IS_FATAL ANY)"
  )
endfunction()
