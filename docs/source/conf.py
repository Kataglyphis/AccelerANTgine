# Sphinx configuration: https://www.sphinx-doc.org/en/master/usage/configuration.html

import pathlib
import re

# An editable install from the hub's nested DocumANTation (requirements.txt).
from sphinx_kataglyphis import brand, setup_theme

_DOCS_SOURCE_DIR = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = _DOCS_SOURCE_DIR.parents[1]
_DOXYGEN_XML_DIR = _REPO_ROOT / "build" / "build" / "xml"
_HAS_API = _DOXYGEN_XML_DIR.exists()

# -- Project information -----------------------------------------------------

PROJECT = "AccelerANTgine"


def _cmake_project_version() -> str:
    """VERSION of CMakeLists.txt's first project(), the one CPack stamps."""
    cmake_lists = _REPO_ROOT / "CMakeLists.txt"
    text = cmake_lists.read_text(encoding="utf-8")
    call = re.search(r"^\s*project\s*\(([^)]*)\)", text, re.IGNORECASE | re.MULTILINE)
    version = re.search(r"\bVERSION\s+(\d+(?:\.\d+)*)", call.group(1)) if call else None
    if version is None:
        raise RuntimeError(f"No VERSION in the first project() of {cmake_lists}")
    return version.group(1)


# Author and copyright come from brand.json's identity, as in the hub's docs/conf.py.
setup_theme(
    globals(),
    repository_url=f"{brand()['identity']['github_url']}/{PROJECT}",
    project_name=PROJECT,
    release=_cmake_project_version(),
    extensions_extra=["sphinx.ext.graphviz", "sphinx.ext.inheritance_diagram"]
    + (["breathe", "exhale"] if _HAS_API else []),
)

# -- General configuration ---------------------------------------------------

exclude_patterns = [] if _HAS_API else ["api/**"]

# Staged by ci-coverage.sh in an earlier step, so a docs-only build cannot check it.
linkcheck_ignore = [
    r"^coverage/index\.html$",
    # sourceforge.io answers 403 to GitHub's runners and 200 to a browser (2026-10-19).
    r"^https://[a-z]+\.sourceforge\.io/",
]

if _HAS_API:
    exhale_args = {
        "containmentFolder": "./api",
        "rootFileName": "library_root.rst",
        "rootFileTitle": "Library API",
        "doxygenStripFromPath": "../..",
        "createTreeView": True,
        "contentsDirectives": True,  # Allows nested folder-like structure
        "exhaleExecutesDoxygen": False,  # Doxygen already runs in the project pipeline
        "listingExclude": [
            r"^TEST$",
            r"^FUZZ_TEST$",
            r"^BENCHMARK$",
            r"^BENCHMARK_MAIN$",
            r"^main$",
            r"^KATAGLYPHIS_CPP_API$",
            r"^KATAGLYPHIS_C_API$",
        ],
    }
    breathe_projects = {"AccelerANTgine": str(_DOXYGEN_XML_DIR)}
    breathe_default_project = "AccelerANTgine"

myst_enable_extensions = [
    "dollarmath",  # Enables dollar-based math syntax
    "amsmath",  # Supports extended LaTeX math environments
    "colon_fence",  # Allows ::: for directives
    "deflist",  # Enables definition lists
]

suppress_warnings = [
    "duplicate_declaration.c",
    "docutils",
]

# -- Options for HTML output -------------------------------------------------

# Not test-results: they are Sphinx pages, and html_extra_path directories are dropped from the sources.
html_extra_path = [
    extra_dir.name
    for extra_dir in (_DOCS_SOURCE_DIR / "coverage",)
    if extra_dir.exists()
]

graphviz_output_format = "svg"
