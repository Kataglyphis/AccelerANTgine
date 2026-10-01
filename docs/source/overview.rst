Overview
========

AccelerANTgine provides a native C++ inference library, C API bindings,
Python bindings (nanobind), and CLI tooling.

The API reference is generated from Doxygen XML via Breathe/Exhale and published
under the API section.

Project Layout
--------------

- ``Src/``: core library, CLI entry point, and platform/runtime integration code
- ``Test/commit``: unit tests against the library: the C API, both config
  parsers, the ONNX engine on generated models, YOLO decoding, GStreamer frames
  and the WebRTC streamer
- ``Test/compile``: the embedder contract: the C header as C17, the module
  imports, move-only owners and stable error codes
- ``Test/fuzz``: FuzzTest properties over the parsers and the YOLO decoder,
  built with Clang or clang-cl and run in unit mode
- ``Test/perf``: Google Benchmark over the parsers, inference, detection and
  ``pull_sample``, built in ``RelWithDebInfo`` profile builds
- ``Test/common``: the helpers the suites share, including the ONNX model
  writer that keeps test models out of the repository
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

- ``Debug``: ``commit``, ``compile``, and ``fuzz`` with Clang or clang-cl
- ``RelWithDebInfo``: ``perf``
- ``Release``: none, unless ``KATAGLYPHIS_RELEASE_TESTS`` is on, which builds all
  four (the Windows arm64 lane runs them on ``windows-11-arm``)

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
