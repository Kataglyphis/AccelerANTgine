#!/usr/bin/env bash
# Builds the linux-fuzz-clang tree and fuzzes every FuzzTest target for a while, resuming from a kept corpus.
set -euo pipefail

usage() {
    echo "usage: ci-fuzz.sh [duration per target, default 3m] [corpus directory, default logs/fuzz-corpus]" >&2
}

case "${1-}" in -h | --help) usage; exit 0 ;; esac
duration="${1:-3m}"
corpus="${2:-logs/fuzz-corpus}"
[[ "${duration}" =~ ^[0-9]+[smh]$ ]] || { echo "ci-fuzz.sh: duration must look like 90s, 3m or 1h, not '${duration}'" >&2; usage; exit 2; }

cmake --preset linux-fuzz-clang
cmake --build build-fuzz -j "${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}" --target fuzzTestSuite
mkdir -p "${corpus}"
corpus="$(cd "${corpus}" && pwd)"
cd build-fuzz
mapfile -t targets < <(./fuzzTestSuite --list_fuzz_tests 2>/dev/null | sed -n 's/^\[\*\] Fuzz test: //p')
[ "${#targets[@]}" -gt 0 ] || { echo "ci-fuzz.sh: the suite lists no fuzz test" >&2; exit 1; }
# The in-process engine reads and grows one directory per target, as the targets' inputs differ in type.
failed=()
for target in "${targets[@]}"; do
    mkdir -p "${corpus}/${target}"
    echo "== ${target} for ${duration} (corpus: $(find "${corpus}/${target}" -type f | wc -l) inputs)"
    FUZZTEST_TESTSUITE_IN_DIR="${corpus}/${target}" FUZZTEST_TESTSUITE_OUT_DIR="${corpus}/${target}" \
        ./fuzzTestSuite --fuzz="${target}" --fuzz_for="${duration}" || failed+=("${target}")
done
if [ "${#failed[@]}" -gt 0 ]; then
    echo "::error title=Fuzzing found a failure::${failed[*]}" >&2
    exit 1
fi
echo "ci-fuzz.sh: ${#targets[@]} targets, no finding; corpus: $(find "${corpus}" -type f | wc -l) inputs"
