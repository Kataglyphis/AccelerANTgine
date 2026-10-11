#!/usr/bin/env bash
# ci-python-bindings.sh - the Python wheels, GIL (cp314) and free-threaded (cp314t), each installed and tested.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

WORKSPACE_DIR="$(pwd)"
OUT_DIR="dist/python"
BUILD_ROOT="/tmp/kataglyphis-pywheels"
PYTHON_VERSION="3.14"
COMPILER="clang"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --build-root) BUILD_ROOT="${2:-}"; shift 2 ;;
    --python-version) PYTHON_VERSION="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

case "${COMPILER}" in
  clang) CC_BIN="clang"; CXX_BIN="clang++" ;;
  gcc) CC_BIN="gcc"; CXX_BIN="g++" ;;
  *) die "--compiler must be clang or gcc, got '${COMPILER}'" ;;
esac

command -v uv >/dev/null 2>&1 || die "uv is not on PATH; the family image ships it"
cd "${WORKSPACE_DIR}"
[[ "${OUT_DIR}" = /* ]] || OUT_DIR="${WORKSPACE_DIR}/${OUT_DIR}"
PROVER="${ANTFRASTRUCTURE_DIR}/linux/scripts/02-toolchain/python/free-threaded-wheel.py"
[[ -f "${PROVER}" ]] || die "missing ${PROVER}; the pinned ANTfrastructure predates the free-threaded prover"
DIST_NAME="kataglyphis-inference"
TAG="cp${PYTHON_VERSION//./}"

# The image's interpreters only: a download would test a Python no consumer of the image has.
find_python() {
  local request="$1" found
  found="$(UV_PYTHON_DOWNLOADS=never uv python find --system "${request}" 2>/dev/null)" ||
    die "no ${request} interpreter in this image (uv python find ${request})"
  printf '%s\n' "${found}"
}

# One wheel per ABI: build, install into its own venv, prove (free-threaded only), then run Test/python.
build_and_test() {
  local label="$1" request="$2" abi="$3"
  local python wheel venv
  python="$(find_python "${request}")"
  info "=== ${label}: ${python} ==="
  rm -rf "${OUT_DIR:?}/${label}"
  # scikit-build-core configures the whole project; Ninja because the module scanning needs it.
  CMAKE_GENERATOR=Ninja CC="${CC_BIN}" CXX="${CXX_BIN}" \
    uv build --wheel --python "${python}" --out-dir "${OUT_DIR}/${label}" \
    -C "build-dir=${BUILD_ROOT}/build-${label}" "${WORKSPACE_DIR}"

  local wheels=("${OUT_DIR}/${label}"/*-"${TAG}"-"${abi}"-linux_*.whl)
  [[ -f "${wheels[0]}" && ${#wheels[@]} -eq 1 ]] ||
    die "${label}: expected one *-${TAG}-${abi}-linux_*.whl in ${OUT_DIR}/${label}, found: $(ls "${OUT_DIR}/${label}")"
  wheel="${wheels[0]}"
  info "${label}: built $(basename "${wheel}")"

  venv="${BUILD_ROOT}/venv-${label}"
  rm -rf "${venv}"
  uv venv --python "${python}" "${venv}"
  # Without its dependencies first, so the proof sees this wheel's modules and nothing else.
  uv pip install --python "${venv}/bin/python" --no-deps "${wheel}"
  if [[ "${abi}" == "${TAG}t" ]]; then
    "${venv}/bin/python" -I "${PROVER}" prove "${DIST_NAME}" || die "${label}: the free-threaded proof failed"
  fi
  uv pip install --python "${venv}/bin/python" "${wheel}" pytest

  # From outside the tree, so the installed wheel is what imports, not a staged build.
  (cd "${BUILD_ROOT}" &&
    "${venv}/bin/python" -m pytest "${WORKSPACE_DIR}/Test/python" -v -p no:cacheprovider \
      -o "junit_family=xunit2" --junitxml="${WORKSPACE_DIR}/logs/python-${label}.xml") ||
    die "${label}: Test/python failed"
}

mkdir -p "${BUILD_ROOT}" "${WORKSPACE_DIR}/logs"
build_and_test gil "${PYTHON_VERSION}+gil" "${TAG}"
build_and_test free-threaded "${PYTHON_VERSION}t" "${TAG}t"
info "Python wheels in ${OUT_DIR}: $(cd "${OUT_DIR}" && ls -- */*.whl | tr '\n' ' ')"
