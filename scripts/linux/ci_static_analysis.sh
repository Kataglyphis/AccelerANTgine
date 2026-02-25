#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="build"
COMPILER="clang"
CLANG_DEBUG_PRESET="linux-debug-clang"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --clang-debug-preset) CLANG_DEBUG_PRESET="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if command -v clang-tidy >/dev/null 2>&1; then
  clang-tidy -p=./"${BUILD_DIR}"/compile_commands.json $(find Src -name "*.cpp" -o -name "*.cc")
else
  echo "clang-tidy not available, skipping"
fi

if [[ "${COMPILER}" == "clang" ]]; then
  set +e
  clang++ --analyze -DUSE_RUST=1 -Xanalyzer -analyzer-output=html $(find Src -name "*.cpp" -o -name "*.cc")
  set -e

  if command -v scan-build-21 >/dev/null 2>&1; then
    mkdir -p scan-build-reports
    scan-build-21 -o scan-build-reports cmake --build "${BUILD_DIR}" --preset "${CLANG_DEBUG_PRESET}"
  else
    echo "scan-build-21 not available, skipping"
  fi
fi
