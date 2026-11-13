#!/usr/bin/env bash
# cxx-mutation-test.sh <ctest regex>: rebuild the configured tree after a mutation, then run the named tests; a C++ recipe's test command.
set -euo pipefail

[ "$#" -eq 1 ] || { printf 'usage: cxx-mutation-test.sh <ctest regex>\n' >&2; exit 2; }
build="${CXX_MUTATION_BUILD_DIR:-build}"
[ -f "${build}/CMakeCache.txt" ] || { printf 'cxx-mutation-test: %s is not configured; build it once with scripts/linux/ci-build-and-test.sh\n' "${build}" >&2; exit 2; }
log="${build}/cxx-mutation-build.log"
# A mutant that does not compile proves nothing about the tests, so it says so instead of passing as caught.
if ! cmake --build "${build}" -j "${CMAKE_BUILD_PARALLEL_LEVEL:-2}" > "${log}" 2>&1; then
  printf 'cxx-mutation-test: the tree does not compile; see %s\n' "${log}" >&2
  tail -n 20 "${log}" >&2
  exit 3
fi
ctest --test-dir "${build}" -R "$1" --output-on-failure -j "${CTEST_PARALLEL_LEVEL:-2}"
