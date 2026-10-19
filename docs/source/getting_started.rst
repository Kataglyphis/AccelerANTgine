Getting Started
===============

AccelerANTgine supports Linux and Windows builds with CMake presets,
containerized CI, and local host-side run scripts.

Prerequisites
-------------

- **C++23** or higher and **C17** or higher; optional: the newest clang, installed
  via apt (see `apt.llvm.org <https://apt.llvm.org/>`_)
- CMake 3.31.6 or newer
- Optional: ``third_party/ANTfrastructure/linux/scripts/02-toolchain/setup-dependencies.sh``
  prepares important dev tools. The dependency installer is ANTfrastructure's;
  this repo does not carry a local copy
- Git submodules checked out
- ONNX Runtime from the family image's chain build: configure searches only
  ``-DONNXRUNTIME_ROOT``, else the image's own prefix, and stops without it
- GStreamer 1.24 or newer, found through pkg-config
- Rust (cargo), unless configured with ``-DRUST_FEATURES=OFF``
- Python tooling for docs when building Sphinx locally
- Docker for the Windows containerized build flow

Install From A Release
----------------------

Linux packages start outside the build image since v0.0.2. Every
`release <https://github.com/Kataglyphis/AccelerANTgine/releases/latest>`_
carries a ``.deb``, a tarball and an AppImage for x86_64 and aarch64, the Windows
installers for x64 and arm64 (setup ``.exe``, MSI, MSIX and zip; arm64's setup
``.exe`` since v0.0.3), and a ``SHA256SUMS``. The Linux packages bring the C++
runtime, ONNX Runtime and the C library they were built against. Up to v0.0.3
only GStreamer comes from the distribution, and the ``.deb`` asks for 1.26 or
newer: Debian 13 (tested on a Raspberry Pi 5) and Ubuntu 26.04 have it, Ubuntu
24.04's 1.24 is too old. After v0.0.3 the packages carry the image's own
GStreamer and its plugins too (owner, 2026-10-17), and the ``.deb`` depends on
glibc and EGL alone (``CHANGELOG.md``, *Unreleased*).

.. code-block:: sh

   sha256sum --check --ignore-missing SHA256SUMS
   sudo apt install ./AccelerANTgine-*-Linux-$(uname -m)-*.deb   # or: unpack the tarball, run usr/bin/AccelerANTgine
   AccelerANTgine --version

Clone The Repository
--------------------

.. code-block:: bash

   git clone --recurse-submodules https://github.com/Kataglyphis/AccelerANTgine.git

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

Each preset names its own build directory, e.g. ``build/`` for
``linux-debug-clang``. From the directory you cloned the repo into:

.. code-block:: bash

   # enlisting all available presets
   cmake --list-presets=all
   cmake --preset <configurePreset-name>
   cmake --build --preset <buildPreset-name>

Rust Features
^^^^^^^^^^^^^

For now the features in Rust are experimental, and they are ON by default:
``RUST_FEATURES`` defaults to ON and every preset but ``x64-Clang-Windows-*``
sets it, so a build needs Rust (cargo) installed, or ``-DRUST_FEATURES=OFF``. In
order to compile a Rust crate on Windows it has to be MSVC ABI compatible, so the
crate's C++ is compiled with the compiler CMake was configured with:
``Src/CMakeLists.txt`` hands ``CC``/``CXX`` to cargo (``corrosion_set_env_vars``),
which is clang-cl under the ClangCL presets.
(``Src/rusty_code/.cargo/config.toml`` is empty.)

``cxxbridge`` needs no install by hand: ``corrosion_add_cxxbridge`` uses one on
``PATH`` only when its version equals the ``cxx`` version in
``Src/rusty_code/Cargo.lock``, and otherwise builds that exact
``cxxbridge-cmd`` into the build tree.

Linux Build And Test
--------------------

For a direct debug build with presets:

.. code-block:: bash

   cmake --preset linux-debug-clang
   cmake --build --preset linux-debug-clang
   cd build && ctest -C Debug --output-on-failure

The Linux CI path is automated through ``scripts/linux/ci-run-all.sh``. That
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

   bash scripts/linux/ci-run-all.sh \
     --compiler clang \
     --runner ubuntu-26.04 \
     --arch x64 \
     --build-type Debug \
     --build-dir build \
     --build-release-dir build-release

Windows Build In Container
--------------------------

The recommended Windows build wrapper is:

.. code-block:: powershell

   .\scripts\windows\Invoke-ContainerBuild.ps1

This hands the build to ANTfrastructure's ``Invoke-ContainerBuild`` (module
``WindowsContainerBuild.Reuse``), which runs
``scripts/windows/Build-Windows.ps1`` inside a REUSABLE container with these
defaults:

- tar-pipe transport into the family workspace path ``C:\ws`` (bind mount only
  via ``-UseBindMount``; a fresh container via ``-FreshContainer``)
- ``--isolation process`` — resource caps apply only under ``-Isolation
  hyperv`` (``-CpuCount``/``-MemoryGb`` knobs)
- artifact delivery back to the host: ``build-<target>`` (verified per lane),
  ``logs`` and ``dist``

The wrapper builds these targets:

- ``clangcl-debug``
- ``clangcl-profile``
- ``clangcl-release``

Artifacts are synchronized back into the repository under:

- ``build-clangcl-debug``
- ``build-clangcl-profile``
- ``build-clangcl-release``
- ``dist/windows-x64``: the release configuration's portable bundle, its
  installers and its MSIX
- ``logs``

Run The App On The Windows Host
-------------------------------

Build in the container, then run outside the container on the Windows host.
Use the host-side scripts from ``scripts/windows``:

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Debug
   .\scripts\windows\Start-Windows.ps1 -Config Profile
   .\scripts\windows\Start-Windows.ps1 -Config Release

The script runs the built executables from the synchronized build folders.
``-Config Debug`` performs a stable CLI check and runs the commit and compile
test suites; a missing or unstartable one fails the run. If you have a
signalling server available, you can opt into the WebRTC smoke test with
``-RunWebRtcSmoke``.

.. _python-bindings:

Python Bindings
---------------

The library is also exposed to Python through nanobind: the module lives in
``Bindings/python`` (``kataglyphis_inference``), its tests in ``Test/python``, and
``scripts/windows/Build-PythonBindings.ps1`` (or
``Invoke-ContainerPythonBindings.ps1``, which runs it inside the ANTfrastructure
Windows image) builds it on Windows and stages the package, with its GStreamer
and chain ONNX Runtime DLLs, into ``build-python/python``. It does not run
``Test/python``: that is the ``python_bindings`` ctest, registered only by a
``KATAGLYPHIS_BUILD_PYTHON_BINDINGS=ON`` configure with ``BUILD_TESTING`` on and
pytest importable.

On Linux the clang leg of both Linux lanes builds two wheels with
``scripts/linux/ci-python-bindings.sh``: ``cp314-cp314`` for the GIL interpreter
and ``cp314-cp314t`` for the image's free-threaded 3.14t. Each is installed into
its own venv and runs ``Test/python``. The free-threaded one first goes through
ANTfrastructure's ``free-threaded-wheel.py prove``, which fails when loading the
module re-enables the GIL. The wheels upload as ``python-wheels-<arch>``. They
are ``linux_<arch>`` wheels: GStreamer and ONNX Runtime come from the image, not
from the wheel.

Without the GIL the module stays safe because ``OnnxInferenceEngine`` and
``YoloDetector`` lock themselves: runs share a ``std::shared_mutex``, and
``initialize`` takes it alone. Every bound field also takes its Python object's
lock (``nb::lock_self()``).

Build Documentation
-------------------

The Sphinx project lives under ``docs/``.

On Linux, the CI docs script installs the required packages and builds the docs:

.. code-block:: bash

   bash scripts/linux/ci-docs.sh \
     --workspace-dir "$(pwd)" \
     --compiler clang \
     --runner ubuntu-26.04 \
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
