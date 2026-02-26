#!/usr/bin/env bash
set -euo pipefail

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
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SRC_FILES=()
while IFS= read -r -d '' file; do
  case "${file}" in
    *.cpp|*.cc|*.cxx|*.ixx|*.cppm|*.mxx) SRC_FILES+=("${file}") ;;
  esac
done < <(find Src -type f -print0)

if [[ ${#SRC_FILES[@]} -gt 0 ]]; then
  IFS=$'\n' SRC_FILES=($(printf '%s\n' "${SRC_FILES[@]}" | sort))
  unset IFS
fi

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
  echo "No C++ source/module files found under Src/, skipping static analysis." >&2
  exit 0
fi

if [[ -f "requirements.txt" ]]; then
  if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    if [[ -d ".venv" ]]; then
      # shellcheck disable=SC1091
      source .venv/bin/activate
    elif [[ -d "venv" ]]; then
      # shellcheck disable=SC1091
      source venv/bin/activate
    else
      if command -v uv >/dev/null 2>&1; then
        uv venv .venv
        # shellcheck disable=SC1091
        source .venv/bin/activate
      else
        echo "uv not available, cannot create Python environment for cmake-format" >&2
      fi
    fi
  fi

  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    if command -v uv >/dev/null 2>&1; then
      uv pip install -r requirements.txt
    else
      python -m pip install -r requirements.txt
    fi
  fi
fi

mapfile -t CMAKE_FILES < <(
  find . -type f \( -name "CMakeLists.txt" -o -name "*.cmake" \) \
    ! -path "./build/*" \
    ! -path "./scan-build-reports/*" | sort
)

if command -v cmake-format >/dev/null 2>&1; then
  if [[ ${#CMAKE_FILES[@]} -gt 0 ]]; then
    cmake-format -i "${CMAKE_FILES[@]}"
  fi
else
  echo "cmake-format not available, skipping"
fi

if command -v clang-tidy >/dev/null 2>&1; then
  clang-tidy -p="${BUILD_DIR}" -header-filter='^Src/' "${SRC_FILES[@]}"
else
  echo "clang-tidy not available, skipping"
fi

if [[ "${COMPILER}" == "clang" ]]; then
  if [[ "${DIRECT_ANALYZE}" == "1" ]]; then
    set +e
    clang++ --analyze -DUSE_RUST=1 -Xanalyzer -analyzer-output=html "${SRC_FILES[@]}"
    set -e
  fi

  if command -v scan-build-21 >/dev/null 2>&1; then
    mkdir -p scan-build-reports
    scan-build-21 -o scan-build-reports cmake --build "${BUILD_DIR}" --preset "${CLANG_DEBUG_PRESET}"
  else
    echo "scan-build-21 not available, skipping"
  fi
fi
