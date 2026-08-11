#!/usr/bin/env bash
# run_static_analysis_format.sh - project wrapper around ContainerHub's generic
# code-quality driver (linux/scripts/lib/code-quality.sh).
#
# Everything reusable now comes from there: the uv/venv bootstrap for
# cmake-format, file discovery, the cmake-format / clang-format runners, the
# compile_commands.json preparation (including the /workspace -> local path
# remap that makes a container-generated DB usable on a dev box) and the
# clang-tidy invocation. Kataglyphis-BeschleunigerBallett has driven the same
# library for months; this repo had a parallel hand-written implementation.
#
# What stays here is genuinely project-specific: the Src/ layout, the module
# extensions this project compiles (.ixx/.cppm/.mxx), its clang-tidy check
# disables, and the two extra analyses no other consumer runs
# (clang++ --analyze and scan-build).
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci_common.sh"

CODE_QUALITY_LIB="${_SCRIPT_DIR}/../../ExternalLib/Kataglyphis-ContainerHub/linux/scripts/lib/code-quality.sh"
if [[ ! -f "${CODE_QUALITY_LIB}" ]]; then
  die "Shared code-quality library not found at '${CODE_QUALITY_LIB}'. Initialize the Kataglyphis-ContainerHub submodule first."
fi
# shellcheck disable=SC1091
source "${CODE_QUALITY_LIB}"

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

mapfile -t FORMAT_FILES < <(code_quality_find_cpp_files Src)
mapfile -t SRC_FILES    < <(code_quality_find_clang_tidy_files Src)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  warn "No C++ source/module files found under Src/, skipping static analysis."
  exit 0
fi

# cmake-format lives in a Python env; the library owns creating it via uv and
# falling back cleanly when uv is absent.
code_quality_ensure_cmake_format || warn "cmake-format environment unavailable, continuing"

mapfile -t CMAKE_FILES < <(code_quality_find_cmake_files)
if command -v cmake-format >/dev/null 2>&1; then
  [[ ${#CMAKE_FILES[@]} -gt 0 ]] && code_quality_run_cmake_format "${CMAKE_FILES[@]}"
else
  warn "cmake-format not available, skipping"
fi

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
