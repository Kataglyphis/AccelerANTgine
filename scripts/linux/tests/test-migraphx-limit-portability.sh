#!/usr/bin/env bash
# Compile the real MIGraphX limit expression with the Windows max macro visible.
set -euo pipefail
# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
root=$SUITE_ROOT work=$SUITE_WORK
line="$(awk '/const std::string memory_limit =/ { print; count++ } END { if (count != 1) exit 1 }' "$root/Src/onnx_inference_engine.cpp")"
[[ "$line" == *SIZE_MAX* ]] || { echo 'MIGraphX limit must survive a max macro and clang-tidy fix' >&2; exit 1; }
{
  printf '%s\n' '#include <cstdint>' '#include <limits>' '#include <string>'
  printf '%s\n' '#define max(a,b) broken_windows_max_macro(a,b)' 'int main() {' "$line"
  printf '%s\n' 'return memory_limit == std::to_string(SIZE_MAX) ? 0 : 1;' '}'
} > "$work/probe.cpp"
if command -v clang-tidy >/dev/null 2>&1 &&
   clang-tidy --checks='-*,readability-redundant-parentheses' --list-checks 2>/dev/null |
     grep -q '^[[:space:]]*readability-redundant-parentheses$'; then
  clang-tidy "$work/probe.cpp" --checks='-*,readability-redundant-parentheses' --fix -- -std=c++23 >/dev/null
else
  echo 'clang-tidy readability-redundant-parentheses unavailable; testing max macro compilation'
fi
"${CXX:-c++}" -std=c++23 "$work/probe.cpp" -o "$work/probe"
"$work/probe"
echo 'PASS: MIGraphX memory limit survives the Windows max macro'
