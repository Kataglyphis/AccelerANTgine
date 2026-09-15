#!/usr/bin/env bash
# run-static-analysis-format.sh - project wrapper around ANTfrastructure's generic
# code-quality driver (linux/scripts/lib/code-quality.sh).
#
# Everything reusable now comes from there: the uv/venv bootstrap for
# cmake-format (the library's own DEFAULT since 19286e9f - see below), file
# discovery, the cmake-format / clang-format runners, the
# compile_commands.json preparation (including the /workspace -> local path
# remap that makes a container-generated DB usable on a dev box) and the
# clang-tidy invocation. BeschleunigerBallett has driven the same
# library for months; this repo had a parallel hand-written implementation.
#
# What stays here is genuinely project-specific: the Src/ layout, the module
# extensions this project compiles (.ixx/.cppm/.mxx), its clang-tidy check
# disables, and the two extra analyses no other consumer runs
# (clang++ --analyze and scan-build).
#
# A MISSING TOOL IS RED HERE, NOT A SKIP. Every analysis runs through
# 01-core/gates.sh (gate_reset / run_gate / assert_gates) and its tools are
# require_tools'd up front, so cmake-format, clang-format, clang-tidy,
# scan-build-21 or clang++ being absent fails the lane instead of quietly
# shrinking it. That is the third of the three buckets in
# third_party/ANTfrastructure/docs/shared-script-libraries.md, "The third
# bucket: a gate that could not RUN":
# a skip is neither a pass nor a failure, it is RED BY DEFAULT, and the inverse
# default - tolerance for free, strictness only if somebody remembers a flag - is
# exactly the shape that let this file ship three warn-and-skip branches and a
# `|| true` while reporting green. If a tool ever genuinely may be absent, record
# it with gate_skip and a reason, and decide about --tolerate-skips deliberately.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source, not a "${_SCRIPT_DIR}/../../third_party/ANTfrastructure/..."
# literal: it resolves under ANTFRASTRUCTURE_DIR (which the literal ignored, so the
# bootstrap's environment override did nothing) and fails naming the probed path
# and the fix. In scope because ci-common.sh sources lib/antfrastructure.sh.
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
# bootstrap venv. Without the excludes the walk reformats ANTfrastructure itself.
CODE_QUALITY_CMAKE_FORMAT_CONFIG=".cmake-format.yaml"
CODE_QUALITY_CMAKE_SEARCH_ROOT="."
CODE_QUALITY_CMAKE_EXCLUDE_PATHS=('./build*/*' './.venv/*' './third_party/*')

mapfile -t FORMAT_FILES < <(code_quality_find_cpp_files Src)
mapfile -t SRC_FILES    < <(code_quality_find_clang_tidy_files Src)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  # Src/ exists and is full of modules, so an empty set is a discovery bug.
  die "No C++ source/module files found under Src/ - check the extension lists above."
fi

# cmake-format lives in a Python env; the library bootstraps it via uv (into
# the venv it then activates) and errs loudly when it cannot.
#
# NO BOOTSTRAP KNOBS ANY MORE. Until 19286e9f the library REFUSED to bootstrap
# unless the caller set CODE_QUALITY_UV_VENV_CREATE_SCRIPT and
# CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT, so this file carried the pair of
# uv wrappers every other consumer also carried. The hub now defaults them to
# exactly that - a uv venv via 01-core/python_uv.sh plus its own pinned
# linux/scripts/cmake-format.requirements.txt - and the default is BETTER than
# what stood here: it installs cmake-format==0.6.13 and pyyaml==6.0.3 rather
# than this repo's whole requirements.txt (sphinx, breathe, exhale, pre-commit)
# to obtain one formatter, and it pins the formatter version, so a gate verdict
# cannot move under a floating release. ci-docs.sh still installs the full
# requirements.txt into the same .venv for the docs build.
code_quality_ensure_cmake_format

# Every tool up front, the missing ones named together (01-core/tool-checks.sh).
# A quality lane without its tool is red, not "continuing".
require_tools cmake cmake-format clang-format clang-tidy scan-build-21 clang++

# Every analysis RUNS, a failure is RECORDED, and the verdict is decided once
# by assert_gates (01-core/gates.sh) - no `|| true`, no warn-and-skip.
gate_reset "static-analysis"

mapfile -t CMAKE_FILES < <(code_quality_find_cmake_files)
if [[ ${#CMAKE_FILES[@]} -eq 0 ]]; then
  # The root CMakeLists.txt always exists, so an empty set is a discovery bug.
  die "cmake-format discovery found no CMake files - check CODE_QUALITY_CMAKE_SEARCH_ROOT/excludes."
fi
run_gate cmake-format code_quality_run_cmake_format "${CMAKE_FILES[@]}"
run_gate clang-format code_quality_run_clang_format "${FORMAT_FILES[@]}"

# ---------------------------------------------------------------------------
# Project-specific analyses: no other ANTfrastructure consumer runs these, so they
# stay local rather than being pushed upstream on a sample size of one.
# ---------------------------------------------------------------------------
run_scan_build() {
  [[ -d "${BUILD_DIR}" ]] || err "Build directory '${BUILD_DIR}' not found - scan-build needs a configured tree."
  mkdir -p scan-build-reports
  scan-build-21 -o scan-build-reports cmake --build "${BUILD_DIR}"
}

# clang-tidy: the DB is generated if the build tree has not produced one yet,
# and the remapped copy is removed whatever the verdict.
run_clang_tidy() {
  if [[ ! -f "${BUILD_DIR}/compile_commands.json" ]]; then
    cmake --preset "${CLANG_DEBUG_PRESET}" -D CMAKE_EXPORT_COMPILE_COMMANDS=ON
  fi
  code_quality_prepare_compile_db "${BUILD_DIR}"
  # Absolute paths: clang-tidy matches entries in the DB by path, and the DB
  # records absolute ones.
  local abs_src_files=() status=0
  mapfile -t abs_src_files < <(printf '%s\n' "${SRC_FILES[@]}" | sed "s#^#$(pwd)/#")
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
  # Deliberate, not a missing tool: a GCC-generated compile_commands.json
  # carries C++ module flags clang-tidy cannot parse (AGENTS.md section 4).
  info "Skipping clang-tidy and scan-build for compiler='${COMPILER}' (clang-only analyses)."
fi

assert_gates
