#!/usr/bin/env bash
# ccc-analyzer drops @response files and -pthread, which CMake's module BMIs need, so this restores both; not nested response files.
set -euo pipefail

# Found beside scan-build, not through $CXX: CMake hands this script to cargo as CXX.
scan_build="$(command -v scan-build)" || { echo "scan-build-cxx.sh: scan-build is not on PATH" >&2; exit 2; }
analyzer="$(dirname "$(readlink -f "${scan_build}")")/../libexec/c++-analyzer"
[[ -x "${analyzer}" ]] || { echo "scan-build-cxx.sh: no c++-analyzer at ${analyzer}" >&2; exit 2; }

args=()
for arg in "$@"; do
  if [[ "${arg}" == @* && -f "${arg#@}" ]]; then
    mapfile -t words < <(python3 -c 'import shlex, sys; print("\n".join(shlex.split(open(sys.argv[1], encoding="utf-8").read())))' "${arg#@}")
    args+=("${words[@]}")
  elif [[ "${arg}" == -pthread ]]; then
    # The analysis would otherwise lack -pthread, and a BMI built with it refuses to load.
    args+=(-pthread -Xclang -pthread)
  else
    args+=("${arg}")
  fi
done
exec "${analyzer}" "${args[@]}"
