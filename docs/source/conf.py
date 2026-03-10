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
    "breathe",
    "exhale",
    "sphinx.ext.graphviz",
    "sphinx.ext.inheritance_diagram",
]

exhale_args = {
    "containmentFolder": "./api",
    "rootFileName": "library_root.rst",
    "rootFileTitle": "Library API",
    "doxygenStripFromPath": "../..",
    "createTreeView": True,
    "contentsDirectives": True,  # Allows nested folder-like structure
    "exhaleExecutesDoxygen": False,  # (optional) if you already run Doxygen manually
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

breathe_projects = {"KataglyphisCppInference": "../../build/build/xml"}
breathe_default_project = "KataglyphisCppInference"

suppress_warnings = [
    "duplicate_declaration.c",
    "docutils",
]


templates_path = ["_templates"]
exclude_patterns = []


# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

# Theme and appearance pulled from the shared baseline.
html_theme = _conf_base.HTML_THEME

html_theme_options = dict(_conf_base.HTML_THEME_OPTIONS)
# Override the repository URL with this project's own repo.
html_theme_options["repository_url"] = (
    "https://github.com/Kataglyphis/KataglyphisCppInference"
)

# copy coverage and raw html/test files into the built site root
# these folders must exist in the docs source directory (docs/coverage, docs/test-results)
html_extra_path = ["coverage", "test-results"]

html_static_path = list(_conf_base.HTML_STATIC_PATH)
# CSS is loaded from the shared baseline; the file itself is symlinked into
# _static/css/ so any template update propagates automatically.
html_css_files = list(_conf_base.HTML_CSS_FILES)

graphviz_output_format = "svg"
