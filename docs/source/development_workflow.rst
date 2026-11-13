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

Five C++ suites link ``AccelerANTgine`` and import its modules, so they test the
library itself; ``Test/python`` tests the Python bindings.

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
       shorter than the class count, YOLOv8/11 ``[1, 4 + C, N]`` columns, the
       ``kataglyphis.output`` metadata behind ``Auto``, labels from the config,
       ``InvalidOutputShape``, the cut to the frame, and every decode case of
       ModelANT's contract through ``decode_detections``); the ORT thread count from the TOML config to the
       session options; XNNPACK and DNNL running or ``ProviderUnavailable``; the MIGraphX plugin's module search,
       registration guard and error paths, with a stand-in module in place of AMD's; GStreamer frames from ``videotestsrc`` and
       ``fakesrc`` through ``appsink``, callbacks and state; the WebRTC stream
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
       rejected, the stream-name mapping, the COCO table, the YOLO decoder on
       arbitrary floats, and ``decode_detections`` on arbitrary shapes, where an
       unreadable shape must be ``InvalidOutputShape`` and every box lies on the
       frame
   * - ``Test/golden``
     - ``goldenTestSuite``
     - The ``golden`` ctest label, native Linux Debug only: the locked model
       (``models/models.lock``, fetched by ``ci-build-and-test.sh``; missing
       fails) with ``Auto`` layout on ModelANT's ``two_cats.jpg`` matches the
       class-15 count and every cat at IoU 0.9 and score 0.05 of
       ``Test/golden/two_cats_cpu.json``, recorded by
       ``AccelerANTgine_demo --detector-image``; a black frame gives 0 boxes;
       XNNPACK's boxes match CPU within 1e-4 (corners as fractions of the frame)
       and its profile names it through the hub's ``verify_ort_profile.py``;
       DNNL matches CPU or is ``ProviderUnavailable``; the demo's ``--threads``
       and ``--config`` reach the session. Re-record the JSON with the demo after
       a model bump
   * - ``Test/perf``
     - ``perfTestSuite``
     - Google Benchmark over the hot paths: both parsers, ``run_inference`` at
       three sizes, YOLO detection with 0, 64 and 512 candidate boxes (NMS is
       quadratic), and ``pull_sample``

No model or media file is checked in for them (the golden suite reads the
fetched model and ModelANT's fixture):
``Test/common/kataglyphis_test_support.h`` writes the ONNX protobuf itself, and
the GStreamer tests use ``videotestsrc`` and ``fakesrc``. A test that needs a
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
in ``docs/coverage/``. ``check-coverage-floor.py`` then fails the lane below
83 % lines / 68 % branches with clang and below 69 % / 50 % with GCC, and prints
``coverage floor: lines <n>% (minimum <floor>%), branches ...``. GCC also counts the
demo program, so ``Test/commit`` runs its command-line refusal paths (``Demo.*``).

``ci-run-all.sh`` runs ``check-junit-skips.py`` over every JUnit report of the leg:
the ctest report, and on clang also the TSan report and the four pytest reports (wheel
tests and text contract, GIL and free-threaded). A skipped
or not-run testcase, a missing report or one without testcases fails the lane.

Each Linux leg uploads ``test-reports-<arch>-<compiler>`` with those reports, the
coverage summary from ``logs/coverage/`` (``ci-profile-bench.sh`` wipes ``build/``) and ``logs/code-quality/clang-tidy.txt``; ``quality-report.toml``
reads them as same-commit artifacts.

``.github/workflows/mutations.yml`` proves these gates can fail. It runs the hub's
``mutation-gates.yml`` over ``scripts/linux/tests/lane-mutations.json``; the recipes
target the skip gate, the coverage floors, the chain-only ORT proof and the static
analysis gates, and their tests feed fixture reports and stub tools:

.. code-block:: bash

   python3 third_party/ANTfrastructure/docs/scripts/verify_mutations.py --root . \
     --manifest scripts/linux/tests/lane-mutations.json

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
- **Benchmark history:** ``perfTestSuite`` writes ``logs/perf/results.json``; CI compares it with
  the median of the last 20 develop results per arch and compiler through the hub's
  ``bench-history`` action (keys ``perf-<arch>-<compiler>``), which warns and never gates on wall
  time, since hosted CPUs differ up to twofold; the instruction-count check gates instead. The detector
  benchmarks read ``models/deim_dfine_n_coco.onnx`` (``fetch-data-lock.py --lock models/models.lock``)
  or ``KATAGLYPHIS_DETECTOR_MODEL``; ``BM_TextGenerateTiny`` reads the hub's configure-time tiny
  GenAI model. Without the model they skip, unless ``KATAGLYPHIS_REQUIRE_MODEL=1``. On Windows,
  ``Start-Windows.ps1 -Config Profile`` writes ``dist\windows-x64\perf\results.json`` and the
  staged arm64 suite writes ``results.json`` beside itself; each lane's ``bench-history`` job
  reports them ungated under ``perf-win-x64`` and ``perf-win-arm64``.
- **Instruction counts:** ``scripts/linux/perf-cachegrind.py --suite build/perfTestSuite --key
  x64-clang`` counts ``BM_PreprocessFrame`` and ``BM_DetectFrame`` per iteration under
  ``valgrind --tool=cachegrind --cache-sim=no`` at one ORT thread, and fails over its
  ``perf/cachegrind-baseline.json`` entry by more than max(3 %, 3 x the recorded spread). It does
  not see wall time, cache misses or threading. ``--summarize`` builds an entry from at least five
  recorded CI runs, each with its CPU model.
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

Every push and PR runs ``powershell-quality.yml``, which calls ANTfrastructure's reusable
``powershell-quality.yml`` over ``scripts`` with ``strict: true``: a unit above 15 cyclomatic, 5 nesting
or 80 function lines fails it. Analyzer warnings stay advisory unless a dispatch sets ``strict``;
a dispatch without it only measures complexity. Split a step into a named function rather than
raising a limit. Its shared bootstrap reads the hub's
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
- **Pinned formatter:** both platforms use ANTfrastructure's ``quality/cmake-format/uv.lock``.
- **Report, never fix:** clang-tidy runs without ``-fix`` on both platforms; the Linux
  findings go to ``logs/code-quality/clang-tidy.txt``. The script's last gate,
  ``sources-unchanged``, runs ``git diff --exit-code -- Src Test``.
- **scan-build on a fresh tree:** it configures ``build-scan-build/`` uncached through
  ``scripts/linux/scan-build-cxx.sh``, which restores the module ``@modmap`` files and
  ``-pthread`` that ccc-analyzer drops, builds the library with ``--status-bugs`` and prints
  ``scan-build: <n> translation unit(s) analysed``. A finding, a unit the analyzer could not
  parse, or 0 units fails the lane.
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

The pre-commit hook installs from the locked docs dependency group:

.. code-block:: bash

   uv sync --locked --only-group docs --python 3.14
   source .venv/bin/activate # .venv/Scripts/activate on pwsh
   pre-commit install
   pre-commit run --all-files   # once, optional

Useful Tools
------------

- `NSIS <https://nsis.sourceforge.io/Main_Page>`_
- `doxygen <https://www.doxygen.nl/index.html>`_
- `cppcheck <https://cppcheck.sourceforge.io/>`_
- `cmake <https://github.com/Kitware/CMake>`_
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

Latency on a quiet host
-----------------------

``bash scripts/linux/quality-report.sh --perf-host`` times the demo's ``--detector-latency-runs`` per
CPU provider, and SmolLM2-135M through the CLI and the Python binding, in the CI image against
``perf/baseline-<cpu>.json``: hub ``third_party/ANTfrastructure/docs/fleet-health.md`` § perf-host. It is not run in CI, whose
hosted wall time varies too much to grade.
