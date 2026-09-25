Overview
========

AccelerANTgine provides a native C++ inference library, C API bindings,
Python bindings (nanobind), and CLI tooling.

The API reference is generated from Doxygen XML via Breathe/Exhale and published
under the API section.

Project Layout
--------------

- ``Src/``: core library, CLI entry point, and platform/runtime integration code
- ``Test/compile``: compilation-level regression tests built in debug mode
- ``Test/commit``: broader debug-mode test suite intended for regular validation
- ``Test/fuzz``: fuzz targets enabled for debug Clang builds on Linux and Windows
- ``Test/perf``: benchmark suite built in ``RelWithDebInfo`` profile builds
- ``Bindings/python``: the ``kataglyphis_inference`` Python module, tested by
  ``Test/python``
- ``docs/source``: Sphinx content and generated API integration points
- ``scripts/linux``: Linux CI orchestration scripts
- ``scripts/windows``: the Windows build script, its container wrappers and the
  host-side run script

Build Matrix Summary
--------------------

The repository already encodes the build matrix in ``CMakePresets.json`` and the
GitHub workflows.

- Linux x64 and arm64 builds run through ``.github/workflows/linux-x64.yml``
  and ``.github/workflows/linux-arm64.yml``, both calling the reusable
  ``.github/workflows/reusable-linux.yml``
- Linux runs execute build, tests, coverage, static analysis, docs, benchmarks,
  and release packaging inside the container image
- Windows x64 builds run through ``.github/workflows/windows-x64.yml`` and the
  arm64 cross build through ``.github/workflows/windows-arm64-cross.yml``, both
  thin callers of ANTfrastructure's reusable ``container-ci-windows.yml``
- Windows builds are done inside the container, while runtime execution is done
  on a host through PowerShell (``Start-Windows.ps1`` for x64; the arm64 product
  runs on GitHub's ``windows-11-arm`` runner)

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
