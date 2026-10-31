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
- Rust (cargo): the crate is part of every build
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
Packaged Linux launchers clear inherited GStreamer plugin, scanner and registry
settings so the shipped plugins load; library embedders retain their own settings.
The host GPU SDK library path is still available to GPU packages.

.. code-block:: sh

   sha256sum --check --ignore-missing SHA256SUMS
   sudo apt install ./AccelerANTgine-*-Linux-$(uname -m)-*.deb   # or: unpack the tarball, run usr/bin/AccelerANTgine
   AccelerANTgine --version

Every package carries the project license and the list of its third-party components with their
license texts: :doc:`third_party_licenses`.

Windows GPU builds stage the image's GStreamer plugins and their runtime dependencies in the
package. The standalone Windows executables clear inherited plugin, scanner and registry
settings when the bundled plugin directory is present; library embedders retain their settings.
``AccelerANTgine --gst_check`` verifies the required elements and their origin;
on Windows it treats the Linux-only camera sources as optional. The cached Windows images
inspected during development lack ``vp8enc``, so the check still fails until the image supplies
it. The install-time license gate also blocks the new plugin closure until the image supplies
verifiable dependency provenance and license texts (ANTfrastructure backlog CON183-CON185).
Existing Windows CPU packages do not yet stage this plugin set, so their clean-host media
capabilities still depend on the locally available GStreamer installation.

ONNX execution providers
------------------------

The library API defaults to CPU. Embedders can choose ``ExecutionProvider::Cuda`` for NVIDIA,
``ExecutionProvider::MigraphX`` for AMD on Linux, or ``ExecutionProvider::DirectML`` for a
DirectX 12 GPU on Windows in either ``SessionConfig`` or ``YoloConfig``. The Python bindings
expose these values as ``OnnxExecutionProvider`` with ``execution_provider`` and ``device_id`` fields.
For the locked DEIM model, Python callers must also set ``YoloConfig.output_layout`` to
``YoloOutputLayout.CornersScoreClass``; the default ``CenterObjectnessScores`` is for YOLOv5 rows.
The existing ``enable_cuda`` field remains supported. A conflicting provider and CUDA request,
negative device ID, or unavailable provider fails initialization. ONNX Runtime may still run
unsupported model operations on its CPU provider. DirectML sessions use sequential execution,
disable memory patterns and serialize inference calls as required by ONNX Runtime.

The installed ``AccelerANTgine_demo`` can profile a model on a selected provider. Fetch the
locked model as described in ``models/README.md``, then run, for example::

   AccelerANTgine_demo --onnx-only --model models/deim_dfine_n_coco.onnx --device cuda --device-id 0 --profile ort-profile

Use ``directml`` on Windows AMD GPUs or ``migraphx`` on Linux AMD GPUs. The device index is a
DXGI adapter index for DirectML and a provider device index for CUDA or MIGraphX. The demo prints
the generated JSON profile path. With ANTfrastructure checked out, confirm model operators ran
on the requested provider using ``python3 -I third_party/ANTfrastructure/shared/python/verify_ort_profile.py
<profile.json> --device cuda`` (use ``python`` on Windows). The demo in a CPU package defaults
to CPU; NVIDIA packages default to CUDA, Linux AMD packages to MIGraphX, and Windows AMD packages
to DirectML. Pass ``--device cpu`` to override a GPU package's default. A requested provider that
cannot initialize fails instead of silently switching to CPU. Profiling is disabled unless ``--profile`` is
provided; an embedder can set ``SessionConfig::profiling_prefix`` and call ``end_profiling()``.
The Linux GPU workflow also runs the locked model on CPU from each finished package using both
the host and bundled glibc loaders. Its optional self-hosted GPU job profiles the packaged demo
from the tarball, extracted AppImage and extracted DEB; the runner needs ``dpkg-deb``. AppImage's
normal entrypoint launches the main application, not the demo. A package's CPU inference alone does
not establish GPU use.
To check the real video path as well, replace ``--onnx-only`` with ``--video-check``. This
creates one synthetic GStreamer video frame, preprocesses it through the same
``VideoDetectorPipeline`` used by applications, and runs the selected ONNX Runtime provider.
When ``--profile`` is supplied, verify that profile with the same provider checker. The GPU
workflow checks both the direct ONNX and video profiles; the video check does not need the
optional GStreamer tensor inference plugins.
The camera and video detection factories also accept a ``YoloConfig`` overload, so callers can
select its execution provider and device instead of the path-only factories' CPU default.

These options require an ONNX Runtime built with the requested provider and its runtime
dependencies. For a top-level Linux package build, ``-DKATAGLYPHIS_ORT_VARIANT=nvidia`` or
``amd`` selects the image's GPU ONNX Runtime and stages its matching provider. CPU is the
default. NVIDIA targets Linux x64 and arm64; AMD targets Linux x64. A GPU package requires
the matching vendor driver and CUDA/cuDNN or ROCm/MIGraphX runtime on the host; set its
``LD_LIBRARY_PATH`` when those libraries are outside the system loader's search path.
The package's GPU variant suffix keeps its archives distinct from CPU archives.
The Debian variants use the same ``accelerantgine`` package identity, so installing a
different variant replaces the installed one.
The Linux tarball and AppImage need the host EGL, Xext and Xrender libraries; on Debian or
Ubuntu install ``libegl1``, ``libxext6`` and ``libxrender1``. The Debian package declares them.
Use the registry's ``:latest-nvidia`` image for NVIDIA builds and ``:latest-rocm`` for AMD.
Packaging derives the provider's direct host dependencies from its ELF imports and rejects
unexpected imports or a host GPU SDK library copied into the package. Dynamically loaded
vendor files are also the host runtime's responsibility.

For a top-level Windows x64 GPU candidate, run
``Build-Windows.ps1 -BuildTargets clangcl-release -OrtVariant nvidia`` inside the registry's
``:winamd64-nvidia`` image, or use ``-OrtVariant amd`` inside ``:winamd64-rocm``. The optional
``-ParallelJobs 8`` limits compiler concurrency on a local machine; omitting it retains the
existing default. The NVIDIA variant stages the CUDA execution provider; the AMD variant uses
DirectML. The NVIDIA
machine needs a compatible NVIDIA driver and CUDA/cuDNN runtime. Both GPU packages let an
embedder explicitly select CPU as well. The image inputs can be checked without building with
``pwsh -File scripts/windows/Test-WindowsGpuImage.ps1 -Variant nvidia -OnnxRoot $env:ONNX_ROOT -WheelDir $env:PYTHON_WHEELS``
or ``-Variant amd`` in the matching registry image. GPU packaging needs a newer hub pin
with provider-aware wheel verification. The NVIDIA check requires x64 core, shared and CUDA
provider DLLs matching the same wheel. The AMD check also requires x64 DirectML matching
that wheel, as does the NVIDIA check when the image includes DirectML.
The DirectML DLL is checked against the image copy and covered by the existing vendor-license
notice. Its upstream redistributable source and original license text have not been independently
verified for these GPU images; see ANTfrastructure backlog CON180.
The candidate build verifies the finished ZIP, MSI and MSIX provider bytes. An isolated NVIDIA
image build with a proposed hub overlay produced all three formats before GStreamer plugin
staging was added; its extracted ZIP ran CPU inference on a clean-path host using a separately
supplied test demo and model. A subsequent
plugin-bearing build stopped at the missing media license provenance gate described above.
The NVIDIA host still needs the compatible CUDA/cuDNN runtime; the local test machine had no
NVIDIA GPU and an explicit CUDA request failed. An AMD-image build also stopped at the media
license gate. Its retained binaries ran CPU and DirectML inference, and a separate instrumented
test build profiled a model operator on the host's AMD adapter. These results do not verify a
finished plugin-bearing GPU package or execution on every target machine.
The manually dispatched Windows GPU workflow labels its outputs unverified and is separate
from releases. The MSI upgrade identity and MSIX
package identity are shared with the CPU build, so switching variants replaces or requires
uninstalling the existing installation; they cannot be installed side by side. Windows ARM
GPU packages are excluded. Neither these checks nor a package build prove GPU inference.

Linux GPU packaging requires the shared ANTfrastructure staging and external-runtime closure APIs.
The currently recorded hub pin does not contain them, so an opt-in build fails during configure
until a published hub revision with those APIs is adopted. The manually dispatched
``Linux GPU package candidates`` workflow is separate from releases and labels its artifacts
unverified; its clean-host job checks CPU inference, not GPU inference. On 2026-10-30 an isolated
AMD x64 release build with those shared changes overlaid matched
the core and provider files to one ONNX Runtime wheel, passed the notices gate, and produced a
TGZ that started on clean Ubuntu with the host and bundled glibc. A later isolated build also
checked the final AMD DEB and AppImage against the same wheel and started both on clean Ubuntu
with each loader path. It did not run a model on an AMD GPU. A successful package build does
not prove GPU execution: verify a model on the target GPU.

Logging
-------

The library and the CLI log through ``kataglyphis::log``. A build with ``NDEBUG`` (Release,
RelWithDebInfo) prints warnings and errors only; a Debug build prints everything.
``ACCELERANTGINE_LOG_LEVEL`` (``debug``, ``info``, ``warning``, ``error`` or ``off``) overrides
that default for any program that loads the library, and the CLI's ``--log_level`` takes the same
values. An embedder can route messages with ``kataglyphis::log::set_sink``. Streaming errors still
reach ``set_error_callback``; logging only adds text.

.. code-block:: sh

   AccelerANTgine --webrtc --source test --log_level info
   ACCELERANTGINE_LOG_LEVEL=debug AccelerANTgine --webrtc --source test

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

The Rust Crate
^^^^^^^^^^^^^^

``Src/rusty_code`` is built and linked into every build, on every platform and preset; the
commit suite calls both of its exports. There is no switch: ``RUST_FEATURES`` is gone
(owner, 2026-10-20). On Windows the crate must be MSVC ABI compatible, so its C++ is compiled
with the compiler CMake was configured with: ``Src/CMakeLists.txt`` hands ``CC``/``CXX`` to
cargo (``corrosion_set_env_vars``), which is clang-cl under the ClangCL presets.
(``Src/rusty_code/.cargo/config.toml`` is empty.)

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

The Windows CLI and demo executables embed the project icon using the shared
ANTfrastructure CMake resource helper.

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
family theme in ``pyproject.toml`` is a path into the recursive submodule checkout, and it needs
Python 3.14):

.. code-block:: bash

   uv sync --locked --only-group docs --python 3.14
   source .venv/bin/activate
   cd docs && make html

CI builds the site in the clang x64 lane and publishes it through ANTfrastructure's
``build-docs.yml``, whose link gate fails on a dead internal link or anchor. The same gate over a
local build:

.. code-block:: bash

   python3 third_party/ANTfrastructure/linux/scripts/verify_site_links.py docs/build/html
