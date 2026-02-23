#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"

if [[ "${COMPILER}" == "gcc" ]]; then
  PRESET="${GCC_DEBUG_PRESET}"
else
  PRESET="${CLANG_DEBUG_PRESET}"
fi

echo "Using preset: ${PRESET}"
cmake -B "${BUILD_DIR}" --preset "${PRESET}"
cmake --build "${BUILD_DIR}" --preset "${PRESET}"

(cd "${BUILD_DIR}" && ctest -C "${BUILD_TYPE}" --verbose --extra-verbose --debug -T test --output-on-failure --output-junit "${WORKSPACE_DIR}/docs/test_results.xml")

if [[ "${COMPILER}" == "clang" ]]; then
  if [[ -x "./${BUILD_DIR}/first_fuzz_test" ]]; then
    "./${BUILD_DIR}/first_fuzz_test"
  else
    echo "first_fuzz_test not found/executable, skipping"
  fi
else
  echo "Compiled with GCC so no fuzz testing!"
fi
