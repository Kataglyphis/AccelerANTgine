#!/usr/bin/env bash
# run-static-analysis-format.sh - project wrapper around ContainerHub's generic
# code-quality driver (linux/scripts/lib/code-quality.sh).
#
# Everything reusable now comes from there: the uv/venv bootstrap for
# cmake-format, file discovery, the cmake-format / clang-format runners, the
# compile_commands.json preparation (including the /workspace -> local path
# remap that makes a container-generated DB usable on a dev box) and the
# clang-tidy invocation. BeschleunigerBallett has driven the same
# library for months; this repo had a parallel hand-written implementation.
#
# What stays here is genuinely project-specific: the Src/ layout, the module
# extensions this project compiles (.ixx/.cppm/.mxx), its clang-tidy check
# disables, and the two extra analyses no other consumer runs
# (clang++ --analyze and scan-build).
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# containerhub_source, not a "${_SCRIPT_DIR}/../../third_party/ContainerHub/..."
# literal: it resolves under CONTAINERHUB_DIR (which the literal ignored, so the
# bootstrap's environment override did nothing) and fails naming the probed path
# and the fix. In scope because ci-common.sh sources lib/containerhub.sh.
containerhub_source linux/scripts/lib/code-quality.sh
containerhub_source linux/scripts/01-core/python_uv.sh

BUILD_DIR="build"
COMPILER="clang"
CLANG_DEBUG_PRESET="linux-debug-clang"
DIRECT_ANALYZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --clang-debug-preset) CLANG_DEBUG_PRESET="${2:-}"; shift 2 ;;
    --direct-analyze) DIRECT_ANALYZE=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# This project compiles C++20 modules, so the module interface extensions have
# to reach BOTH clang-format and clang-tidy. The library's defaults stop at the
# classic extensions.
CODE_QUALITY_CPP_FORMAT_EXTENSIONS=(c cc cpp cxx ixx cppm mxx h hh hpp hxx ipp inl)
CODE_QUALITY_CLANG_TIDY_EXTENSIONS=(cpp cc cxx ixx cppm mxx)

# -fix plus this project's disabled checks. Kept here, not upstream: which
# checks a project tolerates is a project decision.
CODE_QUALITY_CLANG_TIDY_FIX=true
CODE_QUALITY_CLANG_TIDY_ARGS=(
  -checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness
  -header-filter=^Src/
)

# cmake-format inputs: the repo config, and discovery over the whole tree minus
# vendored submodules, every build-*/build_* tree the presets create, and the
# bootstrap venv. Without the excludes the walk reformats ContainerHub itself.
CODE_QUALITY_CMAKE_FORMAT_CONFIG=".cmake-format.yaml"
CODE_QUALITY_CMAKE_SEARCH_ROOT="."
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=('./build*/*' './.venv/*' './third_party/*')

# The library takes the uv venv bootstrap as two *executable* helper paths, but
# this repo is developed with core.filemode=false: a committed helper would
# reach the Linux container as 100644 and die "Permission denied" (the ci-docs.sh
# header documents the incident). Bash runs a function name wherever it expects
# a command, so the helpers are functions over upstream python_uv.sh instead.
cmake_format_uv_venv_create() {
  # Empty python version on purpose: let uv resolve the interpreter
  # (honouring the container's UV_PYTHON) instead of pinning a default.
  uv_venv_create .venv ""
}
cmake_format_uv_install_requirements() {
  uv_pip_install_requirements .venv requirements.txt
}
CODE_QUALITY_UV_VENV_CREATE_SCRIPT=cmake_format_uv_venv_create
CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT=cmake_format_uv_install_requirements

mapfile -t FORMAT_FILES < <(code_quality_find_cpp_files Src)
mapfile -t SRC_FILES    < <(code_quality_find_clang_tidy_files Src)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  warn "No C++ source/module files found under Src/, skipping static analysis."
  exit 0
fi

# cmake-format lives in a Python env; the library bootstraps it via uv and errs
# loudly when it cannot. A quality lane without its tool is red, not "continuing".
code_quality_ensure_cmake_format

mapfile -t CMAKE_FILES < <(code_quality_find_cmake_files)
if [[ ${#CMAKE_FILES[@]} -eq 0 ]]; then
  # The root CMakeLists.txt always exists, so an empty set is a discovery bug.
  die "cmake-format discovery found no CMake files - check CODE_QUALITY_CMAKE_SEARCH_ROOT/excludes."
fi
code_quality_run_cmake_format "${CMAKE_FILES[@]}"

if command -v clang-format >/dev/null 2>&1; then
  [[ ${#FORMAT_FILES[@]} -gt 0 ]] && code_quality_run_clang_format "${FORMAT_FILES[@]}"
else
  warn "clang-format not available, skipping"
fi

# ---------------------------------------------------------------------------
# Project-specific analyses: no other ContainerHub consumer runs these, so they
# stay local rather than being pushed upstream on a sample size of one.
# ---------------------------------------------------------------------------
if [[ "${COMPILER}" == "clang" ]]; then
  if [[ "${DIRECT_ANALYZE}" == "1" ]]; then
    info "Running clang++ --analyze"
    clang++ --analyze -DUSE_RUST=1 -Xanalyzer -analyzer-output=html "${SRC_FILES[@]}" || true
  fi

  if command -v scan-build-21 >/dev/null 2>&1; then
    if [[ -d "${BUILD_DIR}" ]]; then
      info "Running scan-build-21"
      mkdir -p scan-build-reports
      scan-build-21 -o scan-build-reports cmake --build "${BUILD_DIR}"
    else
      warn "Build directory '${BUILD_DIR}' not found, skipping scan-build."
    fi
  else
    warn "scan-build-21 not available, skipping"
  fi
fi

# ---------------------------------------------------------------------------
# clang-tidy. GCC is skipped deliberately: a GCC-generated compile_commands.json
# carries C++ module flags clang-tidy cannot parse.
# ---------------------------------------------------------------------------
if ! command -v clang-tidy >/dev/null 2>&1; then
  warn "clang-tidy not available, skipping"
elif [[ "${COMPILER}" != "clang" ]]; then
  info "Skipping clang-tidy for compiler='${COMPILER}' (GCC module flags are unsupported by clang-tidy)."
else
  # Generate the DB if the build tree has not produced one yet.
  if [[ ! -f "${BUILD_DIR}/compile_commands.json" ]] && command -v cmake >/dev/null 2>&1; then
    cmake --preset "${CLANG_DEBUG_PRESET}" -D CMAKE_EXPORT_COMPILE_COMMANDS=ON
  fi

  if code_quality_prepare_compile_db "${BUILD_DIR}"; then
    # Absolute paths: clang-tidy matches entries in the DB by path, and the DB
    # records absolute ones.
    mapfile -t ABS_SRC_FILES < <(printf '%s\n' "${SRC_FILES[@]}" | sed "s#^#$(pwd)/#")
    code_quality_run_clang_tidy "${CODE_QUALITY_COMPILE_DB_DIR}" "${ABS_SRC_FILES[@]}" || true
    code_quality_cleanup_compile_db
  else
    warn "No compilation database available, skipping clang-tidy."
  fi
fi
