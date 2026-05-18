Overview
========

KataglyphisCppInference provides a native C++ inference library, C API bindings,
and CLI tooling.

The API reference is generated from Doxygen XML via Breathe/Exhale and published
under the API section.

Project Layout
--------------

- ``Src/``: core library, CLI entry point, and platform/runtime integration code
- ``Test/compile``: compilation-level regression tests built in debug mode
- ``Test/commit``: broader debug-mode test suite intended for regular validation
- ``Test/fuzz``: fuzz targets enabled for debug Clang builds on Linux and Windows
- ``Test/perf``: benchmark suite built in ``RelWithDebInfo`` profile builds
- ``docs/source``: Sphinx content and generated API integration points
- ``scripts/linux``: Linux CI orchestration scripts
- ``scripts/windows``: Windows container build wrapper and host-side run scripts

Build Matrix Summary
--------------------

The repository already encodes the build matrix in ``CMakePresets.json`` and the
GitHub workflows.

- Linux x86 and ARM builds run through ``.github/workflows/linux_run.yml``
- Linux runs execute build, tests, coverage, static analysis, docs, benchmarks,
  and release packaging inside the container image
- Windows builds run through ``.github/workflows/windows_run.yml``
- Windows local development builds are done inside the container, while runtime
  execution is done on the host through PowerShell wrappers

Test Suite Selection
--------------------

Top-level CMake selects test suites by build type:

- ``Debug``: ``commit``, ``compile``, and usually ``fuzz``
- ``RelWithDebInfo``: ``perf``
- ``Release``: no default test suite build

This means the most useful local loops are:

- debug build for correctness and fuzz targets
- profile build for benchmarks
- release build for packaging validation

Documentation Scope
-------------------

The Sphinx site is not just API output. It also serves as the project handbook
for:

- setup and local execution
- CI workflow behavior
- test strategy
- architecture notes for newly added features

Each feature change should update the relevant documentation page in the same
change set.
