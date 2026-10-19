Overview
========

AccelerANTgine provides a native C++ inference library, C API bindings, Python bindings
(nanobind) and CLI tooling. The API reference is generated from Doxygen XML via Breathe/Exhale
(:doc:`api_reference`).

Key Features
------------

- Build system: CMake >= 3.31.6
- Performance benchmarks (``Test/perf``)
- Linux and Windows
- Clang, GNU and MSVC
- Rust code called from C++

Project Layout
--------------

- ``Src/``: core library, CLI entry point, and platform/runtime integration code
- ``Test/commit``, ``Test/compile``, ``Test/fuzz``, ``Test/perf``: the four C++ suites
  (:ref:`the-suites`)
- ``Test/common``: the helpers the suites share, including the ONNX model writer that keeps
  test models out of the repository
- ``Bindings/python``: the ``kataglyphis_inference`` Python module, tested by ``Test/python``
- ``docs/source``: Sphinx content and generated API integration points
- ``scripts/linux``: Linux CI orchestration scripts
- ``scripts/windows``: the Windows build script, its container wrappers and the host-side run
  script

Dependencies
------------

Submodules included:

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

.. _build-matrix:

Build Matrix Summary
--------------------

``CMakePresets.json`` and the GitHub workflows encode the build matrix; which lane runs when is
in ``AGENTS.md`` § 5.

- Linux x64 and arm64: ``.github/workflows/linux-x64.yml`` and
  ``.github/workflows/linux-arm64.yml``, both calling the reusable
  ``.github/workflows/reusable-linux.yml``, run the whole ``ci-run-all.sh`` chain (build, tests,
  coverage, static analysis, docs, benchmarks and release packaging; :ref:`linux-build-and-test`)
  inside the container image
- Windows x64: ``.github/workflows/windows-x64.yml``, and the arm64 cross build:
  ``.github/workflows/windows-arm64-cross.yml``, both thin callers of ANTfrastructure's reusable
  ``container-ci-windows.yml``. They build inside the container, run on a host through
  PowerShell (``Start-Windows.ps1`` for x64; the arm64 product runs on GitHub's
  ``windows-11-arm`` runner) and upload ``dist/windows-x64`` or ``dist/windows-arm64``

What CI builds with, in the family's container images:

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

Which suites each build type compiles, and where each lane runs them: :ref:`the-suites`.
