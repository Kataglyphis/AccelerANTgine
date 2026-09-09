#!/usr/bin/env bash
# ci-docs.sh - project wrapper around ContainerHub's generic Sphinx docs builder
# (linux/scripts/lib/docs-build.sh).
#
# What was hand-rolled here and now comes from upstream:
#   * the venv bootstrap and the inline
#     `uv pip install sphinx sphinx-book-theme ... breathe exhale ... junit2html`
#     -> uv_venv_create / uv_pip_install_requirements / uv_venv_activate from
#        ContainerHub 01-core/python_uv.sh, driven by this repo's OWN
#        requirements.txt so the docs toolchain stops being pinned in two places
#        (the inline list and requirements.txt had already drifted by a package).
#   * the _static SVG copy       -> docs_build_copy_static_svg
#   * the graphviz generator run -> docs_build_run_generator
#   * `uv run make html`         -> docs_build_sphinx
#
# TWO GATES THIS TURNS ON. docs_build_sphinx defaults SPHINXOPTS to
# "-W --keep-going" and its target list to (html linkcheck); this repo built with
# neither, i.e. it shipped docs with Sphinx warnings tolerated and dead links
# unchecked. Neither knob is overridden here, on purpose: if the build now fails,
# it is failing on warnings that were always there.
#
# ORDERING FIX (the diagrams): the SVG copy used to run BEFORE the Doxygen step
# below it, so a clean run copied nothing - build/build/html does not exist yet
# at that point - and the site shipped without the Doxygen/Graphviz diagrams. In
# the full ci-run-all chain it was merely one run stale, because ci-profile-bench
# rebuilds build/ and doc_doxygen is an ALL target. The Doxygen block now runs
# ahead of the library steps, so the SVGs that get staged are the ones this run
# just produced.
#
# WHY THE INDIVIDUAL LIBRARY STEPS AND NOT docs_build_main:
# docs_build_prepare_python_env takes the venv bootstrap as two *executable*
# script paths (DOCS_BUILD_UV_VENV_CREATE_SCRIPT /
# DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT) and runs them directly. This repo is
# developed on Windows with core.filemode=false, where git records a new .sh as
# 100644 - such a helper would arrive in the Linux container without its exec bit
# and die with "Permission denied". Every other script in this directory is
# invoked as `bash <path>` for that reason. So the python env is built from the
# very helpers docs_build_prepare_python_env delegates to, and the remaining
# three library steps are called in the order docs_build_main calls them.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/ci-common.sh"

# containerhub_source, not a "${_SCRIPT_DIR}/../../third_party/ContainerHub/..."
# literal: it resolves under CONTAINERHUB_DIR (which the literal ignored, so the
# bootstrap's environment override did nothing) and fails naming the probed path
# and the fix. In scope because ci-common.sh sources lib/containerhub.sh.
containerhub_source linux/scripts/lib/docs-build.sh
containerhub_source linux/scripts/01-core/python_uv.sh

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

  # ---------------------------------------------------------------------------
  # Python environment. uv_venv_create with an explicit empty version lets uv
  # resolve the interpreter (honouring the container's UV_PYTHON) instead of
  # pinning python_uv.sh's default, and uv_pip_install_requirements carries the
  # load-bearing `--python .venv/bin/python` pin: uv honours UV_PYTHON OVER an
  # activated venv, so a plain `uv pip install` targets the image's root-owned
  # /opt/venv and dies with Permission denied for the non-root CI user.
  # ---------------------------------------------------------------------------
  VENV_DIR="${WORKSPACE_DIR}/.venv"
  uv_venv_create "${VENV_DIR}" ""
  uv_pip_install_requirements "${VENV_DIR}" "${WORKSPACE_DIR}/requirements.txt"
  uv_venv_activate "${VENV_DIR}"

  # ---------------------------------------------------------------------------
  # Project-specific pre-Sphinx work, hoisted ahead of the library steps: Doxygen
  # is what writes the SVGs docs_build_copy_static_svg stages, and the XML tree
  # breathe/exhale read (docs/source/conf.py points at build/build/xml).
  # ---------------------------------------------------------------------------
  # Both steps here used to hide behind "if the file exists" guards, so a
  # missing doxygen made this whole block vanish and the lane died twenty lines
  # later on an unexplained `cp: cannot stat .../*.svg`. Both files MUST exist.
  [[ -f "CMakeLists.txt" ]] || die "CMakeLists.txt not found in $(pwd) - ci-docs.sh must run from the repo root (ci-run-all.sh does)."
  # -G Ninja is load-bearing, not taste: this project scans C++ modules, which
  # CMake supports only under Ninja/VS generators - the bare default (Unix
  # Makefiles) fails generate. It never surfaced in the ci-run-all chain because
  # ci-build-and-test.sh had already configured build/ with a Ninja preset and
  # the cache pinned the generator; standalone (fresh build/) it reproduces.
  cmake -S . -B build -G Ninja

  [[ -f "build/Doxyfile" ]] || die "build/Doxyfile missing after configure: enable_doxygen() (ContainerHub cmake/Doxygen.cmake, via cmake/ProjectOptions.cmake) only writes it when find_package(Doxygen) succeeds - is doxygen installed in this image? The SVG staging below hard-requires its output."
  (cd build && doxygen Doxyfile)

  rm -rf docs/source/api
  mkdir -p docs/source/api

  # Also drop Sphinx's incremental state (docs/build holds doctrees + the
  # environment pickle). breathe caches per-file Doxygen state in there, and a
  # stale pickle against regenerated XML dies with "Extension error
  # (breathe.file_state_cache)" - CI never sees it (fresh checkout), local
  # reruns did. The full rebuild costs seconds; the failure cost a debug session.
  rm -rf docs/build

  mkdir -p docs/source/coverage
  mkdir -p docs/source/test-results

  if [ -d "docs/test-results-md" ] && [ "$(ls -A docs/test-results-md 2>/dev/null)" ]; then
    cp -r docs/test-results-md/* docs/source/test-results/
  fi

  # ---------------------------------------------------------------------------
  # Library pipeline: stage the SVGs, generate the diagrams, run Sphinx.
  # DOCS_BUILD_SPHINXOPTS and DOCS_BUILD_TARGETS stay at the library defaults.
  # ---------------------------------------------------------------------------
  DOCS_BUILD_PROJECT_ROOT="${WORKSPACE_DIR}"
  # Anchored to WORKSPACE_DIR: docs_build_copy_static_svg resolves its
  # DESTINATION against DOCS_BUILD_PROJECT_ROOT but its SOURCE against cwd, and
  # --workspace-dir is a public flag, so a bare relative DOCS_OUT could read
  # SVGs from one tree and stage them into another.
  case "${DOCS_OUT}" in
    /*) DOCS_BUILD_SVG_SOURCE_DIR="${DOCS_OUT}" ;;
    *)  DOCS_BUILD_SVG_SOURCE_DIR="${WORKSPACE_DIR}/${DOCS_OUT}" ;;
  esac
  DOCS_BUILD_GENERATOR_SCRIPT="graphviz_generator.py"

  # docs_build_copy_static_svg is a bare `cp *.svg` - with no SVGs it dies with
  # an unexplained "cannot stat", so name the real producer first.
  compgen -G "${DOCS_BUILD_SVG_SOURCE_DIR}/*.svg" >/dev/null \
    || die "Doxygen wrote no SVGs to ${DOCS_BUILD_SVG_SOURCE_DIR}; HAVE_DOT=YES in Doxyfile.in needs graphviz (dot) in the image."
  docs_build_copy_static_svg
  docs_build_run_generator
  docs_build_sphinx

  # ---------------------------------------------------------------------------
  # Test-result rendering. Kept local rather than pushed upstream: nothing else
  # in the fleet converts JUnit XML into the docs site, and a sample size of one
  # is not a library.
  # ---------------------------------------------------------------------------
  # junit2html is in requirements.txt and was just installed into the venv that
  # is active in this shell, so "not available" means the bootstrap above lied
  # about succeeding. This used to warn and skip.
  if ! command -v junit2html >/dev/null 2>&1; then
    die "junit2html not on PATH although requirements.txt installed it into ${VENV_DIR}."
  fi

  shopt -s globstar nullglob
  mkdir -p docs/test-results

  xml_candidates=(
    "${WORKSPACE_DIR}"/**/junit*.xml
    "${WORKSPACE_DIR}"/**/test-results*.xml
    "${WORKSPACE_DIR}"/**/TEST-*.xml
    "${WORKSPACE_DIR}"/**/test-*.xml
  )

  converted_count=0
  skipped_non_junit_count=0
  skipped_empty_count=0

  for f in "${xml_candidates[@]}"; do
    [ -s "$f" ] || {
      skipped_empty_count=$((skipped_empty_count + 1))
      continue
    }
    if grep -qE "<testsuites|<testsuite" "$f"; then
      if junit2html "$f" "${WORKSPACE_DIR}/docs/test-results/$(basename "$f" .xml).html"; then
        converted_count=$((converted_count + 1))
      else
        skipped_non_junit_count=$((skipped_non_junit_count + 1))
      fi
    else
      skipped_non_junit_count=$((skipped_non_junit_count + 1))
    fi
  done

  info "JUnit conversion summary: converted=${converted_count} skipped_non_junit=${skipped_non_junit_count} skipped_empty=${skipped_empty_count}"

  if ! command -v pandoc >/dev/null 2>&1; then
    info "Installing pandoc via apt"
    require_sudo
    apt_install pandoc
  fi
  mkdir -p "${WORKSPACE_DIR}/docs/test-results-md"
  shopt -s globstar nullglob
  html_files=("${WORKSPACE_DIR}"/docs/test-results/*.html)
  if [ ${#html_files[@]} -eq 0 ]; then
    info "No HTML files found in docs/test-results. Skipping pandoc conversion."
  else
    for f in "${html_files[@]}"; do
      pandoc "$f" --verbose -f html -t gfm -o "${WORKSPACE_DIR}/docs/test-results-md/$(basename "$f" .html).md"
    done
  fi

  # Both copies below used to end in `|| true`. The directory is checked on the
  # line above each, so the only thing that swallowed was a real copy failure -
  # and a site silently missing its coverage or test-result pages is exactly
  # what this step exists to prevent.
  SITE_DIR="${WORKSPACE_DIR}/docs/build/html"
  mkdir -p "$SITE_DIR"
  if [[ -d "${WORKSPACE_DIR}/docs/coverage" ]]; then
    mkdir -p "$SITE_DIR/coverage"
    cp -r "${WORKSPACE_DIR}/docs/coverage/." "$SITE_DIR/coverage/"
  fi
  if [[ -d "${WORKSPACE_DIR}/docs/test-results" ]]; then
    mkdir -p "$SITE_DIR/test-results"
    cp -r "${WORKSPACE_DIR}/docs/test-results/." "$SITE_DIR/test-results/"
  fi

  info "Documentation build complete"
fi
