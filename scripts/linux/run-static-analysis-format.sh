#!/usr/bin/env bash
# run-static-analysis-format.sh - format, clang-tidy, scan-build, unchanged Src/Test; a missing tool is red (third_party/ANTfrastructure/docs/shared-script-libraries.md#the-third-bucket-a-gate-that-could-not-run); not GCC tidy/scan-build or _deps/third_party findings.
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

# Report only: an in-place -fix rewrote the checkout CI then built, tested and shipped.
CODE_QUALITY_CLANG_TIDY_FIX=false
# Which checks a project tolerates is its own decision, so they stay here.
CODE_QUALITY_CLANG_TIDY_ARGS=(
  -checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness
  -header-filter=^Src/
)

# Without the excludes the walk grades ANTfrastructure itself.
CODE_QUALITY_CMAKE_FORMAT_CONFIG=".cmake-format.yaml"
CODE_QUALITY_CMAKE_SEARCH_ROOT="."
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=('./build*/*' './.venv/*' './third_party/*')

# Every hand-written C/C++ root, so the format gate grades the files Windows' Get-ProjectCppFiles lists.
FORMAT_ROOTS=(Src Test Bindings cmake)

mapfile -t FORMAT_FILES < <(code_quality_find_cpp_files "${FORMAT_ROOTS[@]}")
mapfile -t SRC_FILES    < <(code_quality_find_clang_tidy_files Src)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  # Src/ exists and is full of modules, so an empty set is a discovery bug.
  die "No C++ source/module files found under Src/ - check the extension lists above."
fi
if [[ ${#FORMAT_FILES[@]} -eq 0 ]]; then
  die "No C/C++ files found under ${FORMAT_ROOTS[*]} - the format gate would grade nothing."
fi

# The library's default bootstrap pins the cmake-format version, so a verdict cannot move under a new release.
code_quality_ensure_cmake_format

# Every tool up front, the missing ones named together.
require_tools cmake cmake-format clang-format clang-tidy scan-build clang++

# Every analysis runs, failures are recorded, and assert_gates decides once.
gate_reset "static-analysis"

mapfile -t CMAKE_FILES < <(code_quality_find_cmake_files)
if [[ ${#CMAKE_FILES[@]} -eq 0 ]]; then
  # The root CMakeLists.txt always exists, so an empty set is a discovery bug.
  die "cmake-format discovery found no CMake files - check CODE_QUALITY_CMAKE_SEARCH_ROOT/excludes."
fi
# --check: in place it rewrote the CI checkout and stayed green over a drifted file (2026-10-12).
run_gate cmake-format code_quality_run_cmake_format --check "${CMAKE_FILES[@]}"

# Releases format differently, so the hub picks the clang-format of its LLVM_RELEASE, or the gate fails.
check_clang_format() {
  code_quality_require_pinned_clang_format
  code_quality_check_clang_format "${FORMAT_FILES[@]}"
  if [[ "${CODE_QUALITY_CLANG_FORMAT_DEVIATIONS}" -gt 0 ]]; then
    err "${CODE_QUALITY_CLANG_FORMAT_DEVIATIONS} file(s) deviate from .clang-format; rewrite them with ${CODE_QUALITY_CLANG_FORMAT} -i."
  fi
}
run_gate clang-format check_clang_format

# quality-report.toml declares this file as the clang-tidy artifact metric.
TIDY_LOG="logs/code-quality/clang-tidy.txt"
SCAN_BUILD_DIR="${BUILD_DIR}-scan-build"
SCAN_BUILD_REPORTS="scan-build-reports"
SCAN_BUILD_TARGET="AccelerANTgine"
# ccc-analyzer falls back to gcc without these, and the scan tree runs uncached: a cache hit would skip the analysis.
SCAN_BUILD_COMPILERS=("--use-cc=clang" "--use-c++=clang++")

# One plist per analysed translation unit; scan-build keeps them with -plist-html --keep-empty.
scan_build_translation_units() {
  find "$1" -type f -name '*.plist' | wc -l
}

# Project-specific analyses: no other consumer runs these.
run_scan_build() {
  local units
  rm -rf -- "${SCAN_BUILD_DIR}" "${SCAN_BUILD_REPORTS}"
  mkdir -p "${SCAN_BUILD_REPORTS}"
  # An already built tree compiles nothing; the preset names clang++ itself, so the tree gets scan-build's wrappers.
  scan-build "${SCAN_BUILD_COMPILERS[@]}" bash -c \
    'cmake --preset "$1" -B "$2" -D COMPILER_CACHE= -D CMAKE_C_COMPILER="${CC}" -D CMAKE_CXX_COMPILER="$3"' \
    configure "${CLANG_DEBUG_PRESET}" "${SCAN_BUILD_DIR}" "${_SCRIPT_DIR}/scan-build-cxx.sh" || return 1
  scan-build "${SCAN_BUILD_COMPILERS[@]}" -o "${SCAN_BUILD_REPORTS}" -plist-html --keep-empty --status-bugs \
    --exclude /_deps/ --exclude /third_party/ \
    cmake --build "${SCAN_BUILD_DIR}" --target "${SCAN_BUILD_TARGET}" || return 1
  # A unit the analyzer could not parse lands in failures/ and was never analysed.
  if [[ -n "$(find "${SCAN_BUILD_REPORTS}" -type d -name failures)" ]]; then
    err "scan-build could not analyse some units; their preprocessed sources are under ${SCAN_BUILD_REPORTS}/*/failures."
    return 1
  fi
  units="$(scan_build_translation_units "${SCAN_BUILD_REPORTS}")"
  info "scan-build: ${units} translation unit(s) analysed"
  [[ "${units}" -gt 0 ]] || { err "scan-build analysed no translation unit; it graded nothing."; return 1; }
}

# clang-tidy -fix is off, so any change under Src or Test here is a tool rewriting the checkout.
check_sources_unchanged() {
  info "git diff --exit-code -- Src Test"
  git -c safe.directory="$(pwd)" diff --exit-code -- Src Test
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
  mkdir -p "$(dirname "${TIDY_LOG}")"
  code_quality_run_clang_tidy "${CODE_QUALITY_COMPILE_DB_DIR}" "${abs_src_files[@]}" >"${TIDY_LOG}" 2>&1 || status=$?
  cat "${TIDY_LOG}"
  code_quality_cleanup_compile_db
  return "${status}"
}

if [[ "${COMPILER}" == "clang" ]]; then
  if [[ "${DIRECT_ANALYZE}" == "1" ]]; then
    run_gate clang-analyze clang++ --analyze -Xanalyzer -analyzer-output=html "${SRC_FILES[@]}"
  fi
  run_gate scan-build run_scan_build
  run_gate clang-tidy run_clang_tidy
else
  # A GCC compile_commands.json carries module flags clang-tidy cannot parse (AGENTS.md section 4).
  info "Skipping clang-tidy and scan-build for compiler='${COMPILER}' (clang-only analyses)."
fi
run_gate sources-unchanged check_sources_unchanged

assert_gates
