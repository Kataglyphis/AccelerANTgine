Overview
========

AccelerANTgine provides a native C++ inference library, C API bindings,
Python bindings (nanobind), and CLI tooling.

The API reference is generated from Doxygen XML via Breathe/Exhale and published
under the API section.

Key Features
------------

.. list-table::
   :header-rows: 1

   * - Category
     - Feature
     - Implement Status
   * - Build System
     - CMake >= 3.31.6
     - ✔️
   * - Performance
     - Performance Benchmark
     - ✔️
   * - Platform Support
     - Linux/Windows support
     - ✔️
   * - Compiler Support
     - Clang/GNU/MSVC support
     - ✔️
   * - Rust integration
     - Call Rust code from C++
     - ✔️

**Legend:** ✔️ completed, 🔶 in progress, ❌ not started.

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

Dependencies
------------

This enumeration also includes submodules.

- `ANTfrastructure <https://github.com/Kataglyphis/ANTfrastructure>`_ — the
  build hub: every reusable script, CMake module, PowerShell module and CI action
  this repo runs comes from ``third_party/ANTfrastructure``, and its gitlink
  decides what the lanes actually execute
- `ONNX Runtime <https://onnxruntime.ai/>`_ — inference
- `GStreamer <https://gstreamer.freedesktop.org/>`_ — media pipelines
- `WebRTC <https://webrtc.org/>`_ — realtime transport, through GStreamer's
  ``webrtcsink``
- `abseil <https://github.com/abseil/abseil-cpp>`_ — pinned at or above the
  version FUZZTEST pins (``AGENTS.md`` § 3)
- `GSL <https://github.com/microsoft/GSL>`_
- `nlohmann_json <https://github.com/nlohmann/json>`_
- `tomlplusplus <https://github.com/marzer/tomlplusplus>`_
- `SPDLOG <https://github.com/gabime/spdlog>`_
- `nanobind <https://github.com/wjakob/nanobind>`_ — the Python bindings
- `gtest <https://github.com/google/googletest>`_
- `gbenchmark <https://github.com/google/benchmark>`_
- `google fuzztest <https://github.com/google/fuzztest>`_

Optional:

- `Rust <https://www.rust-lang.org/>`_
- `corrosion-rs <https://github.com/corrosion-rs/corrosion>`_
- `cxx <https://cxx.rs/>`_

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

Frequently tested under (what CI builds, in the family's container images):

- Windows Server 2025 x64: **clang-cl (LLVM 23)** with the VS 2026 toolset
  (MSVC 14.51); ``cl.exe`` builds (``msvc-debug``, the ``x64-MSVC-*`` presets)
  exist, but no lane runs them
- `clang-cl <https://learn.microsoft.com/de-de/cpp/build/clang-support-msbuild?view=msvc-170>`_
  to compile the Rust crate on Windows
- Windows arm64: a **clang-cl** cross build of the Release and Debug
  configurations, run on ``windows-11-arm``
- Ubuntu 26.04 x64: **Clang 23** and **GCC 16.2**
- Ubuntu 26.04 arm64: **Clang 23** and **GCC 16.2**
- Linux riscv64: cross-built on amd64 with the image's distro clang 22 and tested
  under QEMU (``AGENTS.md`` § 5, *The riscv64 lane*)

Test Suite Selection
--------------------

Top-level CMake selects test suites by build type:

- ``Debug``: ``commit``, ``compile``, and ``fuzz`` with Clang or clang-cl
- ``RelWithDebInfo``: ``perf``
- ``Release``: none, unless ``KATAGLYPHIS_RELEASE_TESTS`` is on, which builds all
  four (both Windows lanes set it through ``Build-Windows.ps1 -StageTests``; the
  arm64 lane runs them on ``windows-11-arm``)

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
