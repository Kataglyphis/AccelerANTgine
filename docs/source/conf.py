# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# ---------------------------------------------------------------------------
# Import shared Kataglyphis theme baseline from ContainerHub template.
# This keeps the look-and-feel in sync: when the template changes, this
# project automatically picks up the new settings on the next build.
# ---------------------------------------------------------------------------
import importlib.util
import pathlib
import sys

_DOCS_SOURCE_DIR = pathlib.Path(__file__).resolve().parent
_REPO_ROOT = _DOCS_SOURCE_DIR.parents[1]
_DOXYGEN_XML_DIR = _REPO_ROOT / "build" / "build" / "xml"

_TEMPLATE_DIR = (
    pathlib.Path(__file__).resolve().parents[2]  # …/KataglyphisCppInference
    / "ExternalLib"
    / "Kataglyphis-ContainerHub"
    / "docs"
    / "source_templates"
    / "sphinx-book"
)

_spec = importlib.util.spec_from_file_location(
    "conf_base", _TEMPLATE_DIR / "conf_base.py"
)
if _spec is None or _spec.loader is None:
    raise ImportError(
        f"Cannot load shared Sphinx baseline from {_TEMPLATE_DIR / 'conf_base.py'}. "
        "Ensure the Kataglyphis-ContainerHub submodule is checked out."
    )
_conf_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_conf_base)

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = "KataglyphisCppInference"
copyright = "2025, Jonas Heinle"
author = "Jonas Heinle"
release = "0.0.1"

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

# Start from the shared extensions, then add project-specific ones.
extensions = list(_conf_base.SPHINX_EXTENSIONS) + [
    "sphinx.ext.graphviz",
    "sphinx.ext.inheritance_diagram",
]

if _DOXYGEN_XML_DIR.exists():
    extensions += ["breathe", "exhale"]
    exclude_patterns = []
else:
    exclude_patterns = ["api/**"]

if _DOXYGEN_XML_DIR.exists():
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

myst_enable_extensions = [
    "dollarmath",  # Enables dollar-based math syntax
    "amsmath",  # Supports extended LaTeX math environments
    "colon_fence",  # Allows ::: for directives
    "deflist",  # Enables definition lists
]

if _DOXYGEN_XML_DIR.exists():
    breathe_projects = {"KataglyphisCppInference": str(_DOXYGEN_XML_DIR)}
    breathe_default_project = "KataglyphisCppInference"

suppress_warnings = [
    "duplicate_declaration.c",
    "docutils",
]
templates_path = ["_templates"]


# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

# Theme and appearance pulled from the shared baseline.
html_theme = _conf_base.HTML_THEME

html_theme_options = dict(_conf_base.HTML_THEME_OPTIONS)
# Override the repository URL with this project's own repo.
html_theme_options["repository_url"] = (
    "https://github.com/Kataglyphis/KataglyphisCppInference"
)

# Copy generated coverage and test-result assets into the built site root when available.
html_extra_path = [
    extra_dir.name
    for extra_dir in (_DOCS_SOURCE_DIR / "coverage", _DOCS_SOURCE_DIR / "test-results")
    if extra_dir.exists()
]

html_static_path = list(_conf_base.HTML_STATIC_PATH)
# CSS is loaded from the shared baseline; the file itself is symlinked into
# _static/css/ so any template update propagates automatically.
html_css_files = list(_conf_base.HTML_CSS_FILES)

graphviz_output_format = "svg"
