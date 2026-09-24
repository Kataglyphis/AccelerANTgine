#!/usr/bin/env python3
"""Render a JUnit XML report as a MyST Markdown page for the Sphinx site.

ci-docs.sh runs this once per report ci-build-and-test.sh wrote with
`ctest --output-junit` (docs/test_results*.xml). It replaced junit2html + pandoc:
the CI image has no pandoc, and its uid-1001 user cannot apt-install one. Sphinx
runs with -W, so the page is plain Markdown: one H1, consecutive heading levels,
no raw HTML.

Usage: junit_to_markdown.py <report.xml> <page.md>
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Lines of a failed test's output kept on the page; the full log stays in CI.
OUTPUT_TAIL_LINES = 80


def page_title(report: Path) -> str:
    """test_results.xml -> "Test results", test_results_tsan.xml -> "Test results (tsan)"."""
    stem = report.stem
    suffix = stem.removeprefix("test_results").strip("_-") if stem.startswith("test_results") else stem
    return f"Test results ({suffix})" if suffix else "Test results"


def outcome(case: ET.Element) -> str:
    if case.find("failure") is not None or case.find("error") is not None:
        return "failed"
    if case.find("skipped") is not None or case.get("status") in ("notrun", "disabled"):
        return "skipped"
    return "passed"


def seconds(value: str | None) -> str:
    try:
        return f"{float(value or 0):.3f}"
    except ValueError:
        return "?"


def code_span(text: str) -> str:
    """Inline code that survives a table cell: pipes escaped, backticks swapped."""
    return "`" + text.replace("`", "'").replace("|", "\\|") + "`"


def fenced(text: str) -> list[str]:
    fence = "```"
    while fence in text:
        fence += "`"
    return [fence + "text", text, fence]


def failure_section(case: ET.Element) -> list[str]:
    problem = case.find("failure")
    if problem is None:
        problem = case.find("error")
    message = (problem.get("message") or "").strip() if problem is not None else ""
    output = (case.findtext("system-out") or "").strip("\n")
    tail = "\n".join(output.splitlines()[-OUTPUT_TAIL_LINES:])
    body = "\n\n".join(part for part in (message, tail) if part) or "(no message, no output)"
    return ["", f"### {code_span(case.get('name', '?'))}", "", *fenced(body)]


def suite_section(suite: ET.Element) -> list[str]:
    cases = suite.findall("testcase")
    results = [outcome(case) for case in cases]
    summary = ", ".join(f"{results.count(kind)} {kind}" for kind in ("passed", "failed", "skipped"))
    when = f", run {suite.get('timestamp')}" if suite.get("timestamp") else ""
    lines = [
        "",
        f"## {code_span(suite.get('name', 'tests'))}",
        "",
        f"{summary} of {len(cases)} ({seconds(suite.get('time'))} s{when}).",
        "",
    ]
    if not cases:
        return lines + ["No test cases."]
    lines += ["| Test | Result | Time (s) |", "| --- | --- | ---: |"]
    lines += [
        f"| {code_span(case.get('name', '?'))} | {result} | {seconds(case.get('time'))} |"
        for case, result in zip(cases, results)
    ]
    for case, result in zip(cases, results):
        if result == "failed":
            lines += failure_section(case)
    return lines


def render(report: Path) -> str:
    root = ET.parse(report).getroot()
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    if not suites:
        raise SystemExit(f"{report}: no <testsuite> element - not a JUnit report")
    lines = [f"# {page_title(report)}"]
    for suite in suites:
        lines += suite_section(suite)
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: junit_to_markdown.py <report.xml> <page.md>", file=sys.stderr)
        return 2
    Path(argv[2]).write_text(render(Path(argv[1])), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
