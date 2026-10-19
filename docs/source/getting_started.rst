Getting Started
===============

Prerequisites
-------------

- **C++23** or higher and **C17** or higher; optional: the newest clang, installed
  via apt (see `apt.llvm.org <https://apt.llvm.org/>`_)
- CMake 3.31.6 or newer
- Optional: ANTfrastructure's
  ``third_party/ANTfrastructure/linux/scripts/02-toolchain/setup-dependencies.sh`` prepares
  important dev tools; this repo carries no local copy
- Git submodules checked out
- ONNX Runtime from the family image's chain build: configure searches only
  ``-DONNXRUNTIME_ROOT``, else the image's own prefix, and stops without it
- GStreamer 1.24 or newer, found through pkg-config
- Rust (cargo), unless configured with ``-DRUST_FEATURES=OFF``
- Python tooling, for a local Sphinx build
- Docker, for the Windows container build

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

Cloned without submodules:

.. code-block:: bash

   git submodule update --init --recursive

Available Build Presets
-----------------------

``CMakePresets.json`` defines them per platform:

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

The Rust features are experimental and ON by default: ``RUST_FEATURES`` defaults to ON and
every preset but ``x64-Clang-Windows-*`` sets it, so a build needs Rust (cargo) installed, or
``-DRUST_FEATURES=OFF``. On Windows the crate must be MSVC ABI compatible, so its C++ is
compiled with the compiler CMake was configured with: ``Src/CMakeLists.txt`` hands
``CC``/``CXX`` to cargo (``corrosion_set_env_vars``), which is clang-cl under the ClangCL
presets. (``Src/rusty_code/.cargo/config.toml`` is empty.)

``cxxbridge`` needs no install by hand: ``corrosion_add_cxxbridge`` uses one on
``PATH`` only when its version equals the ``cxx`` version in
``Src/rusty_code/Cargo.lock``, and otherwise builds that exact
``cxxbridge-cmd`` into the build tree.

.. _linux-build-and-test:

Linux Build And Test
--------------------

A direct debug build with presets:

.. code-block:: bash

   cmake --preset linux-debug-clang
   cmake --build --preset linux-debug-clang
   cd build && ctest -C Debug --output-on-failure

``scripts/linux/ci-run-all.sh`` runs the whole CI path: initialization and dependency checks,
the debug build and tests, coverage, static analysis and formatting checks, profile benchmark
builds, the Sphinx docs and release packaging (the chain in order: ``AGENTS.md`` § 5). For
example:

.. code-block:: bash

   bash scripts/linux/ci-run-all.sh \
     --compiler clang \
     --runner ubuntu-26.04 \
     --arch x64 \
     --build-type Debug \
     --build-dir build \
     --build-release-dir build-release

Windows
-------

Build in the Windows container, then run on the Windows host: :doc:`windows_workflow`.

.. _python-bindings:

Python Bindings
---------------

The library is also exposed to Python through nanobind: the module lives in
``Bindings/python`` (``kataglyphis_inference``), its tests in ``Test/python``.

- **Windows:** ``scripts/windows/Build-PythonBindings.ps1`` (or
  ``Invoke-ContainerPythonBindings.ps1``, which runs it inside the ANTfrastructure Windows
  image) builds the module and stages the package, with its GStreamer and chain ONNX Runtime
  DLLs, into ``build-python/python``. It does not run ``Test/python``: that is the
  ``python_bindings`` ctest, registered only by a ``KATAGLYPHIS_BUILD_PYTHON_BINDINGS=ON``
  configure with ``BUILD_TESTING`` on and pytest importable.
- **Linux:** the clang leg of both Linux lanes builds two wheels with
  ``scripts/linux/ci-python-bindings.sh``: ``cp314-cp314`` for the GIL interpreter and
  ``cp314-cp314t`` for the image's free-threaded 3.14t. Each is installed into its own venv and
  runs ``Test/python``. The free-threaded one first goes through ANTfrastructure's
  ``free-threaded-wheel.py prove``, which fails when loading the module re-enables the GIL. The
  wheels upload as ``python-wheels-<arch>``. They are ``linux_<arch>`` wheels: GStreamer and
  ONNX Runtime come from the image, not from the wheel.

Without the GIL the module stays safe through its own locks; which ones, and what a new bound
class needs: ``AGENTS.md`` § 4.

.. _build-docs:

Build Documentation
-------------------

The Sphinx project lives under ``docs/``. On Linux the CI docs script installs the required
packages and builds the docs:

.. code-block:: bash

   bash scripts/linux/ci-docs.sh \
     --workspace-dir "$(pwd)" \
     --compiler clang \
     --runner ubuntu-26.04 \
     --docs-out build/build/html

A direct docs build, written to ``docs/build/html/index.html``, from the repository root (the
family theme in ``requirements.txt`` is a path into the recursive submodule checkout, and it needs
Python 3.14):

.. code-block:: bash

   uv venv --python 3.14
   source .venv/bin/activate
   uv pip install -r requirements.txt
   cd docs && make html
