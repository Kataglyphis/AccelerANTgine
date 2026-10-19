Development Workflow
====================

This project works best when features, tests, documentation, and refactors are
shipped together in small, verifiable slices.

Recommended Loop
----------------

1. Define the smallest useful feature increment.
2. Implement the behavior in ``Src/``.
3. Add or extend the matching test coverage.
4. Update Sphinx documentation in the same change.
5. Refactor the touched area only after the behavior is covered.
6. Validate with the appropriate local script or preset.

Documentation Rule
------------------

Every non-trivial feature should update the Sphinx project accordingly.

Typical updates:

- ``getting_started`` when user-facing setup or runtime usage changes
- ``overview`` when architecture or capability boundaries change
- a new dedicated page when the feature needs operational guidance,
  examples, or design notes

Test Strategy
-------------

The repository already contains multiple test layers.

The Suites
^^^^^^^^^^

Four C++ suites link ``AccelerANTgine`` and import its modules, so they test the
library itself; a fifth, ``Test/python``, tests the Python bindings.

.. list-table::
   :header-rows: 1
   :widths: 12 16 72

   * - Suite
     - Binary
     - What it covers
   * - ``Test/commit``
     - ``commitTestSuite``
     - The C API; the TOML and JSON config parsers, every rejection path
       included; the ONNX engine on models the tests generate (Relu, Add, two
       outputs, and a Reshape that turns the input into raw YOLO output); YOLO
       decoding (thresholds, classes, NMS, scaling, NaN and infinity, rows
       shorter than the class count); GStreamer frames from ``videotestsrc`` and
       ``appsrc`` through ``appsink``, callbacks and state; the WebRTC stream
       config, its validation and a start against a refusing signalling server
   * - ``Test/compile``
     - ``compileTestSuite``
     - The embedder contract: the C header compiles as C17 and links,
       ``import kataglyphis.c_api`` reaches the same symbol, every module imports
       into one translation unit, the resource owners are move-only, the error
       codes keep their numbers, the defaults agree
   * - ``Test/fuzz``
     - ``fuzzTestSuite``
     - FuzzTest properties over the untrusted inputs: the settings JSON and the
       inference TOML on arbitrary bytes, unsigned fields that round-trip or are
       rejected, the stream-name mapping, the COCO table, and the YOLO decoder on
       arbitrary floats
   * - ``Test/perf``
     - ``perfTestSuite``
     - Google Benchmark over the hot paths: both parsers, ``run_inference`` at
       three sizes, YOLO detection with 0, 64 and 512 candidate boxes (NMS is
       quadratic), and ``pull_sample``

No model or media file is checked in for them:
``Test/common/kataglyphis_test_support.h`` writes the ONNX protobuf itself, and
the GStreamer tests use ``videotestsrc`` and ``appsrc``. A test that needs a
GStreamer element the install lacks skips and names it; the WebRTC ones need
``webrtcsink`` (gst-plugins-rs), which the Linux image has and the Windows image
has not.

Commit, compile and fuzz build in Debug; perf in RelWithDebInfo; all four in
Release with ``-DKATAGLYPHIS_RELEASE_TESTS=ON``, which both Windows lanes set
(``Build-Windows.ps1 -StageTests``). FuzzTest needs Clang or clang-cl. Every lane
runs them:

.. list-table::
   :header-rows: 1

   * - Lane
     - Commit + compile
     - Fuzz (unit mode)
     - Perf
   * - Linux x64, arm64 (clang)
     - ctest, ASan + UBSan with llvm-cov, then again under TSan
     - yes
     - ``ci-profile-bench.sh``
   * - Linux x64, arm64 (GCC)
     - ctest, ASan + UBSan with gcovr
     - — (FuzzTest is Clang-only)
     - ``ci-profile-bench.sh``
   * - Linux riscv64
     - ctest under QEMU, no sanitizers
     - yes
     - — (QEMU timing)
   * - Windows x64
     - Debug: ctest in the container (ASan), then on the runner host; Release:
       staged, on the host
     - yes, Debug and Release
     - Profile build, container and host; Release, by exit code
   * - Windows arm64
     - Release, on ``windows-11-arm``
     - yes
     - yes, by exit code

Run The Suites Locally
^^^^^^^^^^^^^^^^^^^^^^

In the family image:

.. code-block:: sh

   cmake --preset linux-debug-clang && cmake --build build -j
   ctest --test-dir build --no-tests=error --output-on-failure
   ./build/fuzzTestSuite                       # about a second per property
   FUZZTEST_FUZZ_FOR=60s ./build/fuzzTestSuite  # longer, still unit mode

Coverage
^^^^^^^^

``scripts/linux/ci-coverage.sh`` reports llvm-cov on the clang lane (over
``lib/libAccelerANTgine.so``) and gcovr on the GCC lane, where
``linux-debug-GNU`` now builds with ``myproject_ENABLE_COVERAGE``. The HTML lands
in ``docs/coverage/``.

Python Tests
^^^^^^^^^^^^

The Python bindings test suite (``Test/python``) runs against both installed
wheels, GIL and free-threaded (see :ref:`python-bindings`).
``test_threading.py`` calls one engine, detector and config from eight threads at
once.

Unit And Regression Tests
^^^^^^^^^^^^^^^^^^^^^^^^^

- Add logic-focused coverage to the debug suites in ``Test/compile`` and
  ``Test/commit``
- Prefer small deterministic tests for library behavior and boundary cases

Integration Tests
^^^^^^^^^^^^^^^^^

Add integration coverage when a change spans:

- CLI to library interactions
- optional dependency discovery
- packaging/runtime path behavior
- C API to library boundaries

Fuzz Tests
^^^^^^^^^^

Use ``Test/fuzz`` for inputs that are difficult to enumerate manually, such as:

- configuration files
- CLI argument combinations
- parser inputs
- externally provided model metadata or request payloads

Performance Tests
^^^^^^^^^^^^^^^^^

Use ``Test/perf`` for changes that claim measurable runtime impact, such as:

- inference startup time
- repeated execution performance
- pipeline setup costs
- serialization or preprocessing hot paths

``ci-profile-bench.sh`` is the profiling and benchmark lane, and it is what CI
runs:

.. code-block:: bash

   bash scripts/linux/ci-profile-bench.sh

It links gperftools' ``libprofiler`` (``google-perftools``,
``libgoogle-perftools-dev``) when configure finds it, which writes
``logs/profile.prof``; reading that profile takes Go's ``pprof`` (plus
``graphviz`` for its graphs), which the lane itself never calls.
``valgrind --tool=callgrind`` is reached through
``bash scripts/linux/ci-release.sh --callgrind``, and ``perf record`` needs a
``perf`` binary (Ubuntu 26.04: the ``linux-perf`` package — ``linux-tools-common``
no longer ships one) plus permission to open perf events. Installing them is not
this project's subject — the upstream install instructions for
`gperftools <https://github.com/gperftools/gperftools>`__,
`pprof <https://github.com/google/pprof>`__,
`valgrind <https://valgrind.org/docs/manual/cl-manual.html>`__ and
`perf <https://perfwiki.github.io/main/>`__ are the ones that stay correct. The CI
image has ``perf`` (``linux-perf`` 7.0.0-38.38, checked 2026-10-19), but CI cannot
open perf events: the lane runs as the image's uid 1001, which has no
capabilities even under ``--privileged``, and the GitHub runners set
``perf_event_paranoid`` to 4. So the probe fails there, and the lane warns, runs
the workload for a short window without a recorder, then runs the benchmarks.
The image also carries gperftools' ``libprofiler`` (2.18.1, checked 2026-10-16), so that
window writes ``logs/profile.prof`` on both arches; a host without it falls back
to ``-pg``. **On arm64 the script picks gperftools' generic_fp stack walker**:
the default, ``libgcc``, unwinds from inside the profiler's signal handler and
crashed the workload with a segfault in 6 of 140 starts at 4 kHz on a Pi 5 (one
CI run on 2026-10-16), while ``generic_fp`` crashed in none of 210 and gave
slightly deeper stacks, since clang keeps arm64's frame records at ``-O3``.
x86_64 keeps the default, where clang drops frame pointers. Setting
``TCMALLOC_STACKTRACE_METHOD`` yourself overrides the choice.

A ``perf`` binary alone does not make a profile. The profiled workload is the
CLI's WebRTC producer on its synthetic source (``--webrtc --source test``), which
only streams while a signalling server answers; with none it gives up about
200 ms in. ``ci-profile-bench.sh`` therefore starts
``gst-webrtc-signalling-server`` (gst-plugins-rs; the image has it) on
``127.0.0.1:18443`` for the window and points the CLI there, unless
``--profile-args`` names a ``--server`` of its own. ``--signalling-port`` moves
it.

Refactoring Cadence
-------------------

Periodic refactoring is encouraged, but it should stay grounded in tested code.

Prefer refactors that:

- reduce duplication in frequently touched code paths
- clarify runtime or dependency boundaries
- simplify test setup
- improve naming and control flow without changing behavior

Avoid broad cleanup passes that are not tied to active work unless there is
clear payoff and sufficient coverage.

Validation Targets
------------------

Choose the smallest validation path that still proves the change.

- Linux debug correctness: ``cmake --preset linux-debug-clang``
- Linux TSan validation: ``cmake --preset linux-debug-clang-tsan``
- Linux profile benchmarks: ``cmake --preset linux-profile-clang``
- Windows debug/profile/release container builds: ``.\scripts\windows\Invoke-ContainerBuild.ps1``
- Windows host execution:
  ``.\scripts\windows\Start-Windows.ps1 -Config Debug|Profile|Release``

Static Analysis And Formatting
------------------------------

One entry point per platform, and CI runs exactly these:

.. code-block:: bash

   bash scripts/linux/run-static-analysis-format.sh

.. code-block:: powershell

   pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1

They cover cmake-format and clang-format everywhere, plus clang-tidy and
``scan-build`` on the Linux clang lane and clang-tidy in the Windows
``clangcl-debug`` build, over the files the project actually compiles (``.ixx``,
``.cppm`` and ``.mxx`` included). ``clang++ --analyze`` runs only when asked for
(``--direct-analyze``). cmake-format rewrites in place, and so does clang-format
on Windows. On Linux, clang-format checks and does not rewrite. It covers every
C/C++ file under ``Src/``, ``Test/``, ``Bindings/`` and ``cmake/``, and fails the
lane when one of them deviates from ``.clang-format``. It also refuses any
clang-format but the hub's ``LLVM_RELEASE`` (23.1.3), because each release
formats differently. To fix a file, run that release's ``clang-format -i`` on it;
the image's ``clang-format`` is that release. Every tool here is a gate: a tool
that is not installed fails the lane rather than being skipped.

``.clang-format`` and ``.cmake-format.yaml`` here are **shared** configs, and
``scripts/linux/run-lint-gates.sh`` checks them against ANTfrastructure's copies
(the rows of ``.antfrastructure-shared.manifest``) — edit them upstream, not
here. ``.clang-tidy``, ``gcovr.cfg`` and ``.pre-commit-config.yaml`` are this
project's own on purpose; the manifest's header says why. What each tool does
and how to run one of them alone is in ANTfrastructure's
`code-quality-tooling.md <https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/code-quality-tooling.md>`_,
and the configs themselves are described in its
`shared/config/README.md <https://github.com/Kataglyphis/ANTfrastructure/blob/develop/shared/config/README.md>`_.

The pre-commit hook installs from the same ``requirements.txt``:

.. code-block:: bash

   uv venv
   source .venv/bin/activate # .venv/Scripts/activate on pwsh
   uv pip install -r requirements.txt
   pre-commit install
   pre-commit run --all-files   # once, optional

CI Alignment
------------

The GitHub workflows are the reference for how the project is expected to build
and validate:

- Linux workflows orchestrate build, tests, coverage, analysis, docs, and release
- Windows workflows build inside the family container image, run what they
  built (on the x64 runner host, and on ``windows-11-arm`` for the arm64 cross
  build) and upload ``dist/windows-x64`` or ``dist/windows-arm64``

When adding features, keep local verification aligned with those same paths so
CI remains a confirmation step rather than a discovery step.

Useful Tools
------------

- `NSIS <https://nsis.sourceforge.io/Main_Page>`_
- `doxygen <https://www.doxygen.nl/index.html>`_
- `cppcheck <https://cppcheck.sourceforge.io/>`_
- `cmake <https://cmake.org/>`_
- `valgrind <https://valgrind.org/>`_
- `clangtidy <https://github.com/llvm/llvm-project>`_
- `visualstudio <https://visualstudio.microsoft.com/de/>`_
- `ClangPowerTools <https://www.clangpowertools.com/>`_
- `Codecov <https://app.codecov.io/gh>`_
- `Ccache <https://ccache.dev/>`_
- `Sccache <https://github.com/mozilla/sccache>`_

Benchmarking:

- `gperftools <https://github.com/gperftools/gperftools>`_

VSCode extensions:

- `CMake format <https://github.com/cheshirekow/cmake_format>`_
- `CMake tools <https://marketplace.visualstudio.com/items?itemName=ms-vscode.cmake-tools>`_
- `CppTools <https://github.com/microsoft/vscode-cpptools>`_

Literature
----------

Some very helpful literature, tutorials, etc.

Rust:

- `rust-lang <https://www.rust-lang.org/>`_

CMake/C++:

- `ClangCL <https://clang.llvm.org/docs/MSVCCompatibility.html>`_
- `Cpp best practices <https://github.com/cpp-best-practices/cppbestpractices>`_
- `Integrate Rust into CMake projects <https://github.com/trondhe/rusty_cmake>`_
- `corrosion-rs <https://github.com/corrosion-rs/corrosion>`_
- `cxx <https://cxx.rs/>`_
- `C++ Software Design by Klaus Iglberger <https://meetingcpp.com/2024/Speaker/items/Klaus_Iglberger.html>`_
