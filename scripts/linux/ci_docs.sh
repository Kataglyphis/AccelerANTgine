#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_DIR="$(pwd)"
COMPILER="clang"
RUNNER="ubuntu-24.04"
DOCS_OUT="build/build/html"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="${2:-}"; shift 2 ;;
    --compiler) COMPILER="${2:-}"; shift 2 ;;
    --runner) RUNNER="${2:-}"; shift 2 ;;
    --docs-out) DOCS_OUT="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "${COMPILER}" == "clang" && "${RUNNER}" == "ubuntu-24.04" ]]; then
  if [[ ! -d ".venv" ]]; then
    uv venv
  fi
  . ".venv/bin/activate"
  uv pip install \
    sphinx \
    sphinx-rtd-theme \
    sphinx_design \
    myst-parser \
    pyyaml \
    cmake-format \
    breathe \
    exhale \
    pre-commit \
    junit2html

  if [[ -d "${DOCS_OUT}" ]]; then
    mkdir -p docs/source/_static
    cp "${DOCS_OUT}"/*.svg ./docs/source/_static 2>/dev/null || true
  fi

  if [[ -f "docs/source/graphviz_generator.py" ]]; then
    (cd docs/source && uv run python graphviz_generator.py)
  fi

  if [[ -f "CMakeLists.txt" ]]; then
    cmake -S . -B build
  fi

  if [[ -f "build/Doxyfile" ]]; then
    (cd build && doxygen Doxyfile)
  fi

  rm -rf docs/source/api
  mkdir -p docs/source/api

  mkdir -p docs/source/coverage
  mkdir -p docs/source/test-results

  if [ -d "docs/test-results-md" ] && [ "$(ls -A docs/test-results-md 2>/dev/null)" ]; then
    cp -r docs/test-results-md/* docs/source/test-results/
  fi

  if [[ -f "docs/Makefile" || -f "docs/make.bat" ]]; then
    (cd docs && uv run make html)
  fi

  if command -v junit2html >/dev/null 2>&1; then
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

    echo "JUnit conversion summary: converted=${converted_count} skipped_non_junit=${skipped_non_junit_count} skipped_empty=${skipped_empty_count}"
  else
    echo "junit2html not available, skipping"
  fi

  if command -v pandoc >/dev/null 2>&1; then
    :
  else
    apt-get update && apt-get install -y pandoc
  fi
  mkdir -p "${WORKSPACE_DIR}/docs/test-results-md"
  shopt -s globstar nullglob
  html_files=("${WORKSPACE_DIR}"/docs/test-results/*.html)
  if [ ${#html_files[@]} -eq 0 ]; then
    echo "No HTML files found in docs/test-results. Skipping pandoc conversion."
  else
    for f in "${html_files[@]}"; do
      pandoc "$f" --verbose -f html -t gfm -o "${WORKSPACE_DIR}/docs/test-results-md/$(basename "$f" .html).md"
    done
  fi

  SITE_DIR="${WORKSPACE_DIR}/docs/build/html"
  mkdir -p "$SITE_DIR"
  if [[ -d "${WORKSPACE_DIR}/docs/coverage" ]]; then
    mkdir -p "$SITE_DIR/coverage"
    cp -r "${WORKSPACE_DIR}/docs/coverage/." "$SITE_DIR/coverage/" || true
  fi
  if [[ -d "${WORKSPACE_DIR}/docs/test-results" ]]; then
    mkdir -p "$SITE_DIR/test-results"
    cp -r "${WORKSPACE_DIR}/docs/test-results/." "$SITE_DIR/test-results/" || true
  fi
fi
