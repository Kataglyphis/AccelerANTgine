#!/usr/bin/env bash
# Runs run-static-analysis-format.sh against stub tools in a scratch Git tree; it does not run real clang-tidy or scan-build.
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
hub="${root}/third_party/ANTfrastructure"

# The hub with its formatter bootstraps replaced, so only this project's gate logic runs.
mkdir -p "${work}/hub/linux/scripts/lib"
ln -s "${hub}/linux/scripts/01-core" "${work}/hub/linux/scripts/01-core"
for file in "${hub}"/linux/scripts/lib/*; do ln -s "${file}" "${work}/hub/linux/scripts/lib/"; done
rm "${work}/hub/linux/scripts/lib/code-quality.sh"
cat > "${work}/hub/linux/scripts/lib/code-quality.sh" <<SH
source "${hub}/linux/scripts/lib/code-quality.sh"
code_quality_ensure_cmake_format() { :; }
code_quality_run_cmake_format() { :; }
code_quality_require_pinned_clang_format() { :; }
code_quality_check_clang_format() { CODE_QUALITY_CLANG_FORMAT_DEVIATIONS=0; }
code_quality_prepare_compile_db() { CODE_QUALITY_COMPILE_DB_DIR="\$1"; }
code_quality_cleanup_compile_db() { :; }
SH

# Stub tools; STUB_LOG records each call, and the STUB_* knobs plant a finding, a rewrite or an empty analysis.
mkdir -p "${work}/bin"
for tool in cmake-format clang-format clang++; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/bin/${tool}"
done
cat > "${work}/bin/clang-tidy" <<'SH'
#!/usr/bin/env bash
echo "clang-tidy $*" >> "${STUB_LOG}"
if [[ "${STUB_TIDY_REWRITES:-0}" == 1 ]]; then echo '// rewritten' >> Src/engine.cpp; fi
echo "$(pwd)/Src/engine.cpp:3:5: warning: suspicious division [bugprone-integer-division]"
echo '1 warning generated.' >&2
SH
cat > "${work}/bin/scan-build" <<'SH'
#!/usr/bin/env bash
echo "scan-build $*" >> "${STUB_LOG}"
out='' bugs=0
while [[ "$1" == -* ]]; do
  case "$1" in
    -o|--exclude) [[ "$1" == -o ]] && out="$2"; shift ;;
    --status-bugs) bugs=1 ;;
  esac
  shift
done
CC=/stub/ccc-analyzer CXX=/stub/c++-analyzer "$@" || exit
[[ -n "${out}" ]] || exit 0
mkdir -p "${out}/run"
if [[ "${STUB_SCAN_UNITS:-2}" -gt 0 ]]; then
  for i in $(seq "${STUB_SCAN_UNITS:-2}"); do : > "${out}/run/report-${i}.plist"; done
fi
[[ "${STUB_SCAN_FAILURES:-0}" == 1 ]] && mkdir -p "${out}/run/failures"
[[ "${STUB_SCAN_BUG:-0}" == 1 && "${bugs}" == 1 ]] && exit 1
exit 0
SH
cat > "${work}/bin/cmake" <<'SH'
#!/usr/bin/env bash
echo "cmake $*" >> "${STUB_LOG}"
# A configure into an existing tree would find nothing left to compile.
if [[ "$1" == --preset && "$3" == -B && -e "$4" ]]; then echo "stale scan tree $4" >&2; exit 1; fi
exit 0
SH
chmod +x "${work}/bin/"*

make_tree() {
  rm -rf -- "${work}/tree"
  mkdir -p "${work}/tree/Src" "${work}/tree/Test" "${work}/tree/build" "${work}/tree/build-scan-build"
  : > "${work}/tree/build-scan-build/CMakeCache.txt"
  printf 'int engine() { return 1; }\n' > "${work}/tree/Src/engine.cpp"
  printf 'int test() { return 0; }\n' > "${work}/tree/Test/engine_test.cpp"
  printf 'cmake_minimum_required(VERSION 3.30)\n' > "${work}/tree/CMakeLists.txt"
  printf '[]\n' > "${work}/tree/build/compile_commands.json"
  printf 'build/\nbuild-scan-build/\nscan-build-reports/\nlogs/\n' > "${work}/tree/.gitignore"
  git -C "${work}/tree" init -q
  git -C "${work}/tree" add -A
  git -C "${work}/tree" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
}
analyse() {
  make_tree
  : > "${work}/calls"
  (cd "${work}/tree" && env PATH="${work}/bin:${PATH}" ANTFRASTRUCTURE_DIR="${work}/hub" STUB_LOG="${work}/calls" "$@" \
    bash "${root}/scripts/linux/run-static-analysis-format.sh" --build-dir build) >"${work}/out" 2>&1
}
expect() { SUITE_OUTPUT_LINES=30 suite_expect "$1" "$2" analyse "${@:3}"; }

expect pass 'a clean tree with analysed units passes'
grep '^clang-tidy ' "${work}/calls" | grep -qw -- '-fix' && fail 'clang-tidy ran with -fix'
grep -q 'bugprone-integer-division' "${work}/tree/logs/code-quality/clang-tidy.txt" 2>/dev/null \
  || fail 'the clang-tidy findings did not reach logs/code-quality/clang-tidy.txt'
grep -q 'scan-build: 2 translation unit(s) analysed' "${work}/out" || fail 'the analysed unit count is not printed'
grep '^scan-build .*cmake --build' "${work}/calls" | grep -q -- '--status-bugs' || fail 'scan-build runs without --status-bugs'
grep -qxF "cmake --preset linux-debug-clang -B build-scan-build -D COMPILER_CACHE= -D CMAKE_C_COMPILER=/stub/ccc-analyzer -D CMAKE_CXX_COMPILER=${root}/scripts/linux/scan-build-cxx.sh" "${work}/calls" \
  || fail 'the scan tree is not configured uncached with scan-build'"'"'s compiler wrappers'
grep '^scan-build ' "${work}/calls" | grep -v -- '--use-c++=clang++' && fail 'a scan-build call lets ccc-analyzer fall back to g++'
grep -q '^cmake --build build-scan-build --target AccelerANTgine$' "${work}/calls" || fail 'scan-build does not build the library target'

expect fail 'scan-build analysing no unit fails' STUB_SCAN_UNITS=0
expect fail 'a scan-build finding fails' STUB_SCAN_BUG=1
expect fail 'a unit the analyzer could not parse fails' STUB_SCAN_FAILURES=1
expect fail 'a tool rewriting Src fails' STUB_TIDY_REWRITES=1
grep -q 'sources-unchanged: FAILED' "${work}/out" || fail 'the rewrite was not caught by sources-unchanged'

make_tree
printf 'int engine() { return 2; }\n' > "${work}/tree/Src/engine.cpp"
rc=0
(cd "${work}/tree" && env PATH="${work}/bin:${PATH}" ANTFRASTRUCTURE_DIR="${work}/hub" STUB_LOG="${work}/calls" \
  bash "${root}/scripts/linux/run-static-analysis-format.sh" --build-dir build --compiler gcc) >"${work}/out" 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] && grep -q 'sources-unchanged: FAILED' "${work}/out" \
  || fail "the GCC leg must also refuse a changed Src (exit ${rc})"

# scan-build-cxx.sh hands c++-analyzer the module map's flags and -pthread for the analysis too.
mkdir -p "${work}/libexec" "${work}/unit"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "${work}/libexec/c++-analyzer"
chmod +x "${work}/libexec/c++-analyzer"
printf '%s\n' '-x c++-module' '-fmodule-file="kataglyphis.log=Src/My Dir/log.pcm"' > "${work}/unit/log.modmap"
(cd "${work}/unit" && PATH="${work}/bin:${PATH}" bash "${root}/scripts/linux/scan-build-cxx.sh" \
  -c log.cpp @log.modmap -pthread -o log.o) > "${work}/argv" 2>&1 || fail "scan-build-cxx.sh failed: $(cat "${work}/argv")"
printf '%s\n' -c log.cpp -x c++-module '-fmodule-file=kataglyphis.log=Src/My Dir/log.pcm' -pthread -Xclang -pthread -o log.o \
  | diff - "${work}/argv" >&2 || fail 'scan-build-cxx.sh did not expand the module map and restore -pthread'

suite_finish static-analysis
echo 'static-analysis gates: all cases passed'
