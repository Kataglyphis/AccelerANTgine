Getting Started
===============

KataglyphisCppInference supports Linux and Windows builds with CMake presets,
containerized CI, and local host-side run scripts.

Prerequisites
-------------

- C++23-capable compiler toolchain
- CMake 3.31.6 or newer
- Git submodules checked out
- Python tooling for docs when building Sphinx locally
- Docker for the Windows containerized build flow

Clone The Repository
--------------------

.. code-block:: bash

   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-Cpp-Inference.git

If you cloned without submodules:

.. code-block:: bash

   git submodule update --init --recursive

Available Build Presets
-----------------------

The repository already defines platform-specific presets in ``CMakePresets.json``.

- Linux debug: ``linux-debug-clang``, ``linux-debug-GNU``
- Linux thread sanitizer: ``linux-debug-clang-tsan``
- Linux profile: ``linux-profile-clang``, ``linux-profile-GNU``
- Linux release: ``linux-release-clang``, ``linux-release-GNU``
- Windows debug: ``x64-ClangCL-Windows-Debug``, ``x64-MSVC-Windows-Debug``
- Windows profile: ``x64-ClangCL-Windows-Profile``
- Windows release: ``x64-ClangCL-Windows-Release``, ``x64-MSVC-Windows-Release``

You can inspect them with:

.. code-block:: bash

   cmake --list-presets=all

Linux Build And Test
--------------------

For a direct debug build with presets:

.. code-block:: bash

   cmake --preset linux-debug-clang
   cmake --build --preset linux-debug-clang
   cd build && ctest -C Debug --output-on-failure

The Linux CI path is automated through ``scripts/linux/ci_run_all.sh``. That
script orchestrates:

- initialization and dependency checks
- debug build and test execution
- coverage generation
- static analysis and formatting checks
- profile benchmark builds
- Sphinx documentation generation
- release packaging

Example:

.. code-block:: bash

   bash scripts/linux/ci_run_all.sh \
     --compiler clang \
     --runner ubuntu-24.04 \
     --arch x64 \
     --build-type Debug \
     --build-dir build \
     --build-release-dir build-release

Windows Build In Container
--------------------------

The recommended Windows build wrapper is:

.. code-block:: powershell

   .\scripts\windows\start_build.ps1

This launches the Windows container image and runs
``scripts/windows/Build-Windows.ps1`` inside it with these host-local defaults:

- ``--cpus 32``
- ``--memory 48g``
- bind mount of the repository to ``C:\workspace`` inside the container

The wrapper builds these targets:

- ``clangcl-debug``
- ``clangcl-profile``
- ``clangcl-release``

Artifacts are synchronized back into the repository under:

- ``build-clangcl-debug``
- ``build-clangcl-profile``
- ``build-clangcl-release``

Run The App On The Windows Host
-------------------------------

Build in the container, then run outside the container on the Windows host.
Use the host-side scripts from ``scripts/windows``:

.. code-block:: powershell

   .\scripts\windows\start_debug.ps1
   .\scripts\windows\start_profile.ps1
   .\scripts\windows\start_release.ps1

These scripts run the built executables from the synchronized build folders.
``start_debug.ps1`` performs a stable CLI check and executes the debug test
binaries it finds. If you have a signalling server available, you can opt into
the WebRTC smoke test with ``-RunWebRtcSmoke``.

Build Documentation
-------------------

The Sphinx project lives under ``docs/``.

On Linux, the CI docs script installs the required packages and builds the docs:

.. code-block:: bash

   bash scripts/linux/ci_docs.sh \
     --workspace-dir "$(pwd)" \
     --compiler clang \
     --runner ubuntu-24.04 \
     --docs-out build/build/html

For a direct docs build:

.. code-block:: bash

   uv venv
   source .venv/bin/activate
   uv pip install -r requirements.txt
   cd docs && make html

Generated HTML is written to ``docs/build/html/index.html``.

Next Steps
----------

- See :doc:`overview` for the current architecture summary.
- See :doc:`development_workflow` for the feature, docs, test, and refactor loop.
- See :doc:`windows_workflow` for the Windows-specific build and run workflow.
