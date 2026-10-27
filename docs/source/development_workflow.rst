Development Workflow
====================

Ship features, tests, documentation and refactors together, in small verifiable slices.

Recommended Loop
----------------

1. Define the smallest useful feature increment.
2. Implement the behavior in ``Src/``.
3. Add or extend the matching test coverage.
4. Update Sphinx documentation in the same change.
5. Refactor the touched area only after the behavior is covered.
6. Validate with the appropriate local script or preset (`Validation Targets`_).

Documentation Rule
------------------

The Sphinx site is the project handbook, not just API output: setup and local execution, CI
workflow behavior, test strategy, and architecture notes for new features. Every non-trivial
feature updates it in the same change:

- ``getting_started`` when user-facing setup or runtime usage changes
- ``overview`` when architecture or capability boundaries change
- a new dedicated page when the feature needs operational guidance,
  examples, or design notes

Test Strategy
-------------

.. _the-suites:

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
       config, its validation and a start against a refusing signalling server;
       both exports of the Rust crate, through cxx and ``extern "C"``
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

Top-level CMake selects the suites by build type: commit, compile and fuzz in Debug; perf in
RelWithDebInfo; none in Release unless ``-DKATAGLYPHIS_RELEASE_TESTS=ON``, which builds all four
and which both Windows lanes set (``Build-Windows.ps1 -StageTests``). FuzzTest needs Clang or
clang-cl. Every lane runs them:

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

Eight Linux CI entry scripts for build/test, coverage, docs, initialization, profiling, Python
bindings, finalization and the full chain share the value-option parser in ``ci-common.sh``.
It calls ANTfrastructure's ``parse_cli_value_options`` and keeps each script's own accepted
options and defaults. Repeated options still use the last value, unknown options still fail,
and a missing value now names its
flag instead of producing Bash's ``shift`` error. The standalone regression runs before builds
in the Linux lint workflow and writes its CI log under ignored ``logs/test-results/``:

.. code-block:: bash

   bash scripts/linux/tests/test-ci-value-options.sh

The test covers each option map, argument boundaries, default retention, caller wiring and
broken-map mutants. It does not execute CMake, test binaries or package creation.

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

Where A New Test Goes
^^^^^^^^^^^^^^^^^^^^^

.. list-table::
   :header-rows: 1
   :widths: 60 40

   * - The change
     - The test
   * - Library logic and boundary cases
     - small deterministic tests in the debug suites ``Test/compile`` and ``Test/commit``
   * - Spans CLI to library interactions, optional dependency discovery, packaging/runtime path
       behavior, or C API to library boundaries
     - integration coverage
   * - Takes inputs that are difficult to enumerate manually: configuration files, CLI argument
       combinations, parser inputs, externally provided model metadata or request payloads
     - ``Test/fuzz``
   * - Claims measurable runtime impact: inference startup time, repeated execution
       performance, pipeline setup costs, serialization or preprocessing hot paths
     - ``Test/perf``

Profiling
^^^^^^^^^

``ci-profile-bench.sh`` is the profiling and benchmark lane, and it is what CI
runs:

.. code-block:: bash

   bash scripts/linux/ci-profile-bench.sh

- **gperftools:** configure links ``libprofiler`` (``google-perftools``,
  ``libgoogle-perftools-dev``) when it finds it, and the profiled window writes
  ``logs/profile.prof``; a host without it falls back to ``-pg``. The image carries it (2.18.1,
  checked 2026-10-16), so CI's window writes the profile on both arches. Reading it takes Go's
  ``pprof`` (plus ``graphviz`` for its graphs), which the lane itself never calls.
- **On arm64 the script picks gperftools' generic_fp stack walker.** The default, ``libgcc``,
  unwinds from inside the profiler's signal handler and crashed the workload with a segfault in
  6 of 140 starts at 4 kHz on a Pi 5 (one CI run on 2026-10-16), while ``generic_fp`` crashed in
  none of 210 and gave slightly deeper stacks, since clang keeps arm64's frame records at
  ``-O3``. x86_64 keeps the default, where clang drops frame pointers. Setting
  ``TCMALLOC_STACKTRACE_METHOD`` yourself overrides the choice.
- **callgrind:** ``valgrind --tool=callgrind`` is reached through
  ``bash scripts/linux/ci-release.sh --callgrind``.
- **perf:** ``perf record`` needs a ``perf`` binary (Ubuntu 26.04: the ``linux-perf`` package;
  ``linux-tools-common`` no longer ships one) plus permission to open perf events. The CI image
  has ``perf``, but CI cannot open perf events, so the lane warns, runs the workload for a short
  window without a recorder, then runs the benchmarks. The profiled workload, the CLI's WebRTC
  producer, streams only while a signalling server answers, so the script starts one on
  ``127.0.0.1:18443`` for the window (``--signalling-port`` moves it) unless
  ``--profile-args`` names a ``--server`` of its own. Why, with the measurements:
  ``AGENTS.md`` § 4.

Installing the tools is not this project's subject; the upstream install instructions for
`gperftools <https://github.com/gperftools/gperftools>`__,
`pprof <https://github.com/google/pprof>`__,
`valgrind <https://valgrind.org/docs/manual/cl-manual.html>`__ and
`perf <https://perfwiki.github.io/main/>`__ are the ones that stay correct.

Refactoring Cadence
-------------------

Refactor periodically, but only tested code. Prefer refactors that:

- reduce duplication in frequently touched code paths
- clarify runtime or dependency boundaries
- simplify test setup
- improve naming and control flow without changing behavior

Avoid broad cleanup passes that are not tied to active work unless there is
clear payoff and sufficient coverage.

Validation Targets
------------------

Choose the smallest validation path that still proves the change: a debug build for correctness
and fuzz targets, a profile build for benchmarks, a release build for packaging validation.

- Linux debug correctness: ``cmake --preset linux-debug-clang``
- Linux TSan validation: ``cmake --preset linux-debug-clang-tsan``
- Linux profile benchmarks: ``cmake --preset linux-profile-clang``
- Windows debug/profile/release container builds: ``.\scripts\windows\Invoke-ContainerBuild.ps1``
- Windows host execution:
  ``.\scripts\windows\Start-Windows.ps1 -Config Debug|Profile|Release``

The GitHub workflows are the reference for how the project builds and validates
(:ref:`build-matrix`); keep local verification on those same paths so CI remains a
confirmation step rather than a discovery step.

Static Analysis And Formatting
------------------------------

One entry point per platform, and CI runs exactly these:

The on-request Windows x64 PowerShell lint job calls ANTfrastructure's reusable
``powershell-quality.yml`` with analyzer warnings advisory. Its shared bootstrap reads the hub's
version pin and retries transient PowerShell Gallery failures; parser failures stay fatal.
The Windows build-wiring Pester suite imports ANTfrastructure's AST reader, which rejects a
malformed build script before checking its build steps.

.. code-block:: bash

   bash scripts/linux/run-static-analysis-format.sh

.. code-block:: powershell

   pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1

- **What runs:** cmake-format and clang-format everywhere, plus clang-tidy and ``scan-build`` on
  the Linux clang lane and clang-tidy in the Windows ``clangcl-debug`` build, over the files the
  project actually compiles (``.ixx``, ``.cppm`` and ``.mxx`` included). ``clang++ --analyze``
  runs only when asked for (``--direct-analyze``).
- **Rewrite or check:** cmake-format rewrites in place, and so does clang-format on Windows. On
  Linux clang-format checks and does not rewrite: it covers every C/C++ file under ``Src/``,
  ``Test/``, ``Bindings/`` and ``cmake/``, and fails the lane when one of them deviates from
  ``.clang-format``.
- **One clang-format release:** the Linux gate grades with the clang-format of the hub's
  ``LLVM_RELEASE`` (23.1.3), because each release formats differently. The hub's
  ``code_quality_require_pinned_clang_format`` looks in ``/usr/local/llvm-target/bin``, then on
  ``PATH``, and fails the gate when neither has that release. To fix a file, run the
  ``clang-format -i`` the gate's error names; the image's ``clang-format`` is that release.
- **Every tool is a gate:** a tool that is not installed fails the lane rather than being
  skipped.
- **Configs:** ``.clang-format`` and ``.cmake-format.yaml`` here are **shared** configs, and
  ``scripts/linux/run-lint-gates.sh`` checks them against ANTfrastructure's copies (the rows of
  ``.antfrastructure-shared.manifest``): edit them upstream, not here. ``.clang-tidy``,
  ``gcovr.cfg`` and ``.pre-commit-config.yaml`` are this project's own on purpose; the
  manifest's header says why. What each tool does and how to run one of them alone is in
  ANTfrastructure's
  `code-quality-tooling.md <https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/code-quality-tooling.md>`_,
  and the configs themselves are described in its
  `shared/config/README.md <https://github.com/Kataglyphis/ANTfrastructure/blob/develop/shared/config/README.md>`_.

The pre-commit hook installs from the same ``requirements.txt``:

.. code-block:: bash

   uv venv --python 3.14   # the docs theme in requirements.txt needs it
   source .venv/bin/activate # .venv/Scripts/activate on pwsh
   uv pip install -r requirements.txt
   pre-commit install
   pre-commit run --all-files   # once, optional

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

Rust:

- `rust-lang <https://www.rust-lang.org/>`_

CMake/C++:

- `ClangCL <https://clang.llvm.org/docs/MSVCCompatibility.html>`_
- `Cpp best practices <https://github.com/cpp-best-practices/cppbestpractices>`_
- `Integrate Rust into CMake projects <https://github.com/trondhe/rusty_cmake>`_
- `corrosion-rs <https://github.com/corrosion-rs/corrosion>`_
- `cxx <https://cxx.rs/>`_
- `C++ Software Design by Klaus Iglberger <https://meetingcpp.com/2024/Speaker/items/Klaus_Iglberger.html>`_
