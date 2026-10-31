#!/usr/bin/env bash
# Compile the real MIGraphX limit expression with the Windows max macro visible.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
line="$(awk '/const std::string memory_limit =/ { print; count++ } END { if (count != 1) exit 1 }' "$root/Src/onnx_inference_engine.cpp")"
[[ "$line" == *SIZE_MAX* ]] || { echo 'MIGraphX limit must survive a max macro and clang-tidy fix' >&2; exit 1; }
{
  printf '%s\n' '#include <cstdint>' '#include <limits>' '#include <string>'
  printf '%s\n' '#define max(a,b) broken_windows_max_macro(a,b)' 'int main() {' "$line"
  printf '%s\n' 'return memory_limit == std::to_string(SIZE_MAX) ? 0 : 1;' '}'
} > "$work/probe.cpp"
if command -v clang-tidy >/dev/null 2>&1; then
  clang-tidy "$work/probe.cpp" --checks='-*,readability-redundant-parentheses' --fix -- -std=c++23 >/dev/null
fi
"${CXX:-c++}" -std=c++23 "$work/probe.cpp" -o "$work/probe"
"$work/probe"
echo 'PASS: MIGraphX memory limit survives the Windows max macro'
