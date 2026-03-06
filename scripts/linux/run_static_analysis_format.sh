#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="build"
COMPILER="clang"
CLANG_DEBUG_PRESET="linux-debug-clang"
DIRECT_ANALYZE=0
COMPILE_DB_PATH=""

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
FORMAT_FILES=()
while IFS= read -r -d '' file; do
  case "${file}" in
    *.cpp|*.cc|*.cxx|*.ixx|*.cppm|*.mxx) SRC_FILES+=("${file}"); FORMAT_FILES+=("${file}") ;;
    *.h|*.hh|*.hpp|*.hxx|*.ipp|*.inl) FORMAT_FILES+=("${file}") ;;
  esac
done < <(find Src -type f -print0)

if [[ ${#SRC_FILES[@]} -gt 0 ]]; then
  IFS=$'\n' SRC_FILES=($(printf '%s\n' "${SRC_FILES[@]}" | sort))
  unset IFS
fi

if [[ ${#FORMAT_FILES[@]} -gt 0 ]]; then
  IFS=$'\n' FORMAT_FILES=($(printf '%s\n' "${FORMAT_FILES[@]}" | sort))
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
        UV_VENV_PYTHON=""
        if [[ -x "/usr/bin/python3" ]]; then
          UV_VENV_PYTHON="/usr/bin/python3"
        elif [[ -x "/usr/local/bin/python3" ]]; then
          UV_VENV_PYTHON="/usr/local/bin/python3"
        fi

        if [[ -n "${UV_VENV_PYTHON}" ]]; then
          uv venv --python "${UV_VENV_PYTHON}" .venv
        else
          uv venv .venv
        fi

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
    ! -path "./ExternalLib/*" \
    ! -path "./scan-build-reports/*" | sort
)

if [[ -f "${BUILD_DIR}/compile_commands.json" ]]; then
  COMPILE_DB_PATH="${BUILD_DIR}/compile_commands.json"
elif command -v cmake >/dev/null 2>&1 && [[ "${COMPILER}" == "clang" ]]; then
  # Ensure a compile database exists so clang-tidy can parse C++ modules correctly.
  cmake --preset "${CLANG_DEBUG_PRESET}" -D CMAKE_EXPORT_COMPILE_COMMANDS=ON
  if [[ -f "${BUILD_DIR}/compile_commands.json" ]]; then
    COMPILE_DB_PATH="${BUILD_DIR}/compile_commands.json"
  fi
fi

if command -v cmake-format >/dev/null 2>&1; then
  if [[ ${#CMAKE_FILES[@]} -gt 0 ]]; then
    cmake-format -i "${CMAKE_FILES[@]}"
  fi
else
  echo "cmake-format not available, skipping"
fi

if command -v clang-format >/dev/null 2>&1; then
  if [[ ${#FORMAT_FILES[@]} -gt 0 ]]; then
    clang-format -i "${FORMAT_FILES[@]}"
  else
    echo "No C/C++ files found to format under Src/, skipping clang-format."
  fi
else
  echo "clang-format not available, skipping"
fi

if [[ "${COMPILER}" == "clang" ]]; then
  if [[ "${DIRECT_ANALYZE}" == "1" ]]; then
    clang++ --analyze -DUSE_RUST=1 -Xanalyzer -analyzer-output=html "${SRC_FILES[@]}" || true
  fi

  if command -v scan-build-21 >/dev/null 2>&1; then
    if [[ -d "${BUILD_DIR}" ]]; then
      mkdir -p scan-build-reports
      scan-build-21 -o scan-build-reports cmake --build "${BUILD_DIR}"
    else
      echo "Build directory '${BUILD_DIR}' not found, skipping scan-build."
    fi
  else
    echo "scan-build-21 not available, skipping"
  fi
fi

if command -v clang-tidy >/dev/null 2>&1; then
  if [[ "${COMPILER}" == "clang" ]]; then
    if [[ -n "${COMPILE_DB_PATH}" ]]; then
      mapfile -t ABS_SRC_FILES < <(printf '%s\n' "${SRC_FILES[@]}" | sed "s#^#$(pwd)/#")
      (
        cd "${BUILD_DIR}"
        clang-tidy --fix -checks='-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness' -p="." -header-filter='^Src/' "${ABS_SRC_FILES[@]}"
      ) || true
    else
      echo "No compilation database found at ${BUILD_DIR}/compile_commands.json, skipping clang-tidy."
    fi
  else
    echo "Skipping clang-tidy for compiler='${COMPILER}'."
    echo "Reason: current compile_commands.json contains GCC C++ modules flags unsupported by clang-tidy."
  fi
else
  echo "clang-tidy not available, skipping"
fi
