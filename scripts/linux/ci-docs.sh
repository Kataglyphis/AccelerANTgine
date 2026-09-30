#!/usr/bin/env bash
# ci-docs.sh - Sphinx docs over ANTfrastructure's docs-build.sh; the venv steps are functions, since core.filemode=false drops a new script's exec bit.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# antfrastructure_source (via ci-common.sh) honours the ANTFRASTRUCTURE_DIR override.
antfrastructure_source linux/scripts/lib/docs-build.sh
antfrastructure_source linux/scripts/01-core/python_uv.sh

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
RUNNER="ubuntu-26.04"
DOCS_OUT="build/build/html"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --runner) RUNNER="${2:-}"; shift 2 ;;
    --docs-out) DOCS_OUT="${2:-}"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "${COMPILER}" == "clang" && "${RUNNER}" == "ubuntu-26.04" ]]; then
  info "Building documentation"

  # Not a plain `uv pip install`: uv honours UV_PYTHON over an active venv and would hit the root-owned /opt/venv.
  VENV_DIR="${WORKSPACE_DIR}/.venv"
  DOCS_BUILD_VENV_DIR="${VENV_DIR}"

  docs_venv_create() { uv_venv_create "${VENV_DIR}" ""; }
  docs_venv_install_requirements() {
    uv_pip_install_requirements "${VENV_DIR}" "${WORKSPACE_DIR}/requirements.txt"
  }

  DOCS_BUILD_UV_VENV_CREATE_SCRIPT=docs_venv_create
  DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT=docs_venv_install_requirements

  # Doxygen runs before the library steps: it writes the SVGs they stage and the XML breathe reads.
  [[ -f "CMakeLists.txt" ]] || die "CMakeLists.txt not found in $(pwd) - ci-docs.sh must run from the repo root (ci-run-all.sh does)."
  # -G Ninja: CMake scans C++ modules only under Ninja/VS generators.
  cmake -S . -B build -G Ninja

  [[ -f "build/Doxyfile" ]] || die "build/Doxyfile missing after configure: enable_doxygen() (ANTfrastructure cmake/Doxygen.cmake, via cmake/ProjectOptions.cmake) only writes it when find_package(Doxygen) succeeds - is doxygen installed in this image? The SVG staging below hard-requires its output."
  (cd build && doxygen Doxyfile)

  rm -rf docs/source/api
  mkdir -p docs/source/api

  # A stale breathe pickle against regenerated XML fails with "Extension error (breathe.file_state_cache)".
  rm -rf docs/build

  mkdir -p docs/source/coverage
  mkdir -p docs/source/test-results

  # Library pipeline; SPHINXOPTS and targets stay at the library defaults (-W, linkcheck).
  DOCS_BUILD_PROJECT_ROOT="${WORKSPACE_DIR}"
  # Anchored: the library resolves the SVG source against cwd but the destination against the project root.
  case "${DOCS_OUT}" in
    /*) DOCS_BUILD_SVG_SOURCE_DIR="${DOCS_OUT}" ;;
    *)  DOCS_BUILD_SVG_SOURCE_DIR="${WORKSPACE_DIR}/${DOCS_OUT}" ;;
  esac
  DOCS_BUILD_GENERATOR_SCRIPT="graphviz_generator.py"

  # The library's bare `cp *.svg` fails with an unexplained "cannot stat", so name the producer first.
  compgen -G "${DOCS_BUILD_SVG_SOURCE_DIR}/*.svg" >/dev/null \
    || die "Doxygen wrote no SVGs to ${DOCS_BUILD_SVG_SOURCE_DIR}; HAVE_DOT=YES in Doxyfile.in needs graphviz (dot) in the image."
  # Steps one by one, not docs_build_main: the test-result pages must land before Sphinx reads them.
  docs_build_prepare_python_env

  # Test-result pages, one per JUnit report ci-build-and-test.sh wrote.
  results_dir="${WORKSPACE_DIR}/docs/source/test-results"
  # Only generated pages match: the hand-written file here is index.rst.
  rm -f "${results_dir}"/*.md
  shopt -s nullglob
  reports=("${WORKSPACE_DIR}"/docs/test_results*.xml)
  shopt -u nullglob
  for report in "${reports[@]}"; do
    "${VENV_DIR}/bin/python" "${_SCRIPT_DIR}/junit_to_markdown.py" \
      "${report}" "${results_dir}/$(basename "${report}" .xml).md"
  done
  info "Test-result pages: rendered ${#reports[@]} JUnit report(s)"
  # The toctree globs this directory, and -W fails an empty glob.
  if [ ${#reports[@]} -eq 0 ]; then
    printf '# No test results\n\nThis documentation build found no JUnit XML to render.\n' \
      > "${results_dir}/no-results.md"
  fi

  docs_build_copy_static_svg
  docs_build_run_generator
  docs_build_sphinx
  info "Sphinx build complete"

  # No `|| true` on the copy: a site silently missing its coverage pages is what this step prevents.
  SITE_DIR="${WORKSPACE_DIR}/docs/build/html"
  mkdir -p "$SITE_DIR"
  if [[ -d "${WORKSPACE_DIR}/docs/coverage" ]]; then
    mkdir -p "$SITE_DIR/coverage"
    cp -r "${WORKSPACE_DIR}/docs/coverage/." "$SITE_DIR/coverage/"
  fi

  info "Documentation build complete"
fi
