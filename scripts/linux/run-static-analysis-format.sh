#!/usr/bin/env bash
# run-static-analysis-format.sh - format, clang-tidy, scan-build; a missing tool is red (hub docs/shared-script-libraries.md, section "The third bucket").
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source (via ci-common.sh) honours the ANTFRASTRUCTURE_DIR override.
antfrastructure_source linux/scripts/lib/code-quality.sh
antfrastructure_source linux/scripts/01-core/gates.sh
antfrastructure_source linux/scripts/01-core/tool-checks.sh

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

# The library's defaults stop at the classic extensions; the module interfaces must reach both tools.
CODE_QUALITY_CPP_FORMAT_EXTENSIONS=(c cc cpp cxx ixx cppm mxx h hh hpp hxx ipp inl)
CODE_QUALITY_CLANG_TIDY_EXTENSIONS=(cpp cc cxx ixx cppm mxx)

# Which checks a project tolerates is its own decision, so they stay here.
CODE_QUALITY_CLANG_TIDY_FIX=true
CODE_QUALITY_CLANG_TIDY_ARGS=(
  -checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness
  -header-filter=^Src/
)

# Without the excludes the walk reformats ANTfrastructure itself.
CODE_QUALITY_CMAKE_FORMAT_CONFIG=".cmake-format.yaml"
CODE_QUALITY_CMAKE_SEARCH_ROOT="."
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=('./build*/*' './.venv/*' './third_party/*')

mapfile -t FORMAT_FILES < <(code_quality_find_cpp_files Src)
mapfile -t SRC_FILES    < <(code_quality_find_clang_tidy_files Src)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  # Src/ exists and is full of modules, so an empty set is a discovery bug.
  die "No C++ source/module files found under Src/ - check the extension lists above."
fi

# The library's default bootstrap pins the cmake-format version, so a verdict cannot move under a new release.
code_quality_ensure_cmake_format

# Every tool up front, the missing ones named together.
require_tools cmake cmake-format clang-format clang-tidy scan-build-21 clang++

# Every analysis runs, failures are recorded, and assert_gates decides once.
gate_reset "static-analysis"

mapfile -t CMAKE_FILES < <(code_quality_find_cmake_files)
if [[ ${#CMAKE_FILES[@]} -eq 0 ]]; then
  # The root CMakeLists.txt always exists, so an empty set is a discovery bug.
  die "cmake-format discovery found no CMake files - check CODE_QUALITY_CMAKE_SEARCH_ROOT/excludes."
fi
run_gate cmake-format code_quality_run_cmake_format "${CMAKE_FILES[@]}"
run_gate clang-format code_quality_run_clang_format "${FORMAT_FILES[@]}"

# Project-specific analyses: no other consumer runs these.
run_scan_build() {
  [[ -d "${BUILD_DIR}" ]] || err "Build directory '${BUILD_DIR}' not found - scan-build needs a configured tree."
  mkdir -p scan-build-reports
  scan-build-21 -o scan-build-reports cmake --build "${BUILD_DIR}"
}

# The remapped DB copy is removed whatever the verdict.
run_clang_tidy() {
  if [[ ! -f "${BUILD_DIR}/compile_commands.json" ]]; then
    cmake --preset "${CLANG_DEBUG_PRESET}" -D CMAKE_EXPORT_COMPILE_COMMANDS=ON
  fi
  code_quality_prepare_compile_db "${BUILD_DIR}"
  # Absolute paths: clang-tidy matches DB entries by path, and the DB records absolute ones.
  local abs_src_files=() status=0
  mapfile -t abs_src_files < <(printf '%s\n' "${SRC_FILES[@]}" | sed "s#^#$(pwd)/#")
  # clang-tidy reads the build's module PCMs, so it must be clang's own LLVM version.
  code_quality_run_clang_tidy "${CODE_QUALITY_COMPILE_DB_DIR}" "${abs_src_files[@]}" || status=$?
  code_quality_cleanup_compile_db
  return "${status}"
}

if [[ "${COMPILER}" == "clang" ]]; then
  if [[ "${DIRECT_ANALYZE}" == "1" ]]; then
    run_gate clang-analyze clang++ --analyze -DUSE_RUST=1 -Xanalyzer -analyzer-output=html "${SRC_FILES[@]}"
  fi
  run_gate scan-build run_scan_build
  run_gate clang-tidy run_clang_tidy
else
  # A GCC compile_commands.json carries module flags clang-tidy cannot parse (AGENTS.md section 4).
  info "Skipping clang-tidy and scan-build for compiler='${COMPILER}' (clang-only analyses)."
fi

assert_gates
