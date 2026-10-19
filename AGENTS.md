# AGENTS.md

Guidance for coding agents (and new contributors) working in AccelerANTgine.

Laid out per ANTfrastructure's
[`shared/templates/AGENTS.md.template`](third_party/ANTfrastructure/shared/templates/AGENTS.md.template).
The rule that shapes it: *would this still be true in a different project?* If
yes, ANTfrastructure owns it and § 2 links to it. If no, it is written out in § 4.

## 1. What this project is

A C++23 inference library, ONNX Runtime for inference and GStreamer for media, with three
surfaces: a C API for native embedders, Python bindings and a CLI. It builds with CMake presets,
and **C++23 named modules** (`.ixx`) shape most of its tooling.

| Path | What lives there |
| --- | --- |
| `Src/` | The library: `onnx_inference_engine`, `yolo_detector`, `gstreamer_pipeline`, `webrtc_streamer`, `toml_config`, `config_loader`, `inference_lib`, `kataglyphis_c_api` (the embedder-facing ABI) and `rusty_code/`. The CLI (`cli_main.cpp`) and the demo (`inference_demo.cpp`, `AccelerANTgine_demo`) are programs of their own, built only when this is the top-level project, so the library carries no `main()` |
| `Bindings/` | Python bindings (`Bindings/python`, tests in `Test/python`) |
| `Test/` | The four C++ suites `commit`, `compile`, `fuzz` and `perf` (`docs/source/development_workflow.rst` § *The Suites*), and `common/`, the helpers that generate their ONNX models; `Test/python` tests the bindings |
| `scripts/linux/` | The `ci-*.sh` chain, run end to end by `ci-run-all.sh`; the lint, static-analysis and Renovate wrappers; `junit_to_markdown.py` (the docs' test-result pages); the `lib/antfrastructure.sh` bootstrap |
| `scripts/windows/` | `Build-Windows.ps1` + its `Build-Windows.config.psd1` table, `Build-PythonBindings.ps1`, the entry points (`Start-Windows.ps1`, `Invoke-Container*.ps1`, `Show-BuildHelp.ps1`), the `Resolve-BuildModule.ps1` bootstrap, the Pester suite in `tests/` and `generated-artifacts.txt`, the pathspecs the hub's generated-artifacts suite reads. No project-local `modules/`: `WindowsOrtBundle.Common`, the ONNX Runtime proof of a staged bundle, became the hub's `WindowsOrtPayload.Common` on 2026-09-25 |
| `third_party/ANTfrastructure` | The submodule owning every reusable script, module and doc |

**This repo is consumed as a direct submodule** of OmniAccelerANT, at
`third_party/AccelerANTgine`. The Flutter plugin `packages/kataglyphis_native_inference` lives
in-tree there and links this repo as a *sibling*: its `windows/CMakeLists.txt` and
`linux/CMakeLists.txt` walk up to the superproject root and `add_subdirectory()` the checkout at
`third_party/AccelerANTgine`. An app sees a change here only after that superproject takes it.

## 2. What ANTfrastructure owns — links only

**Do not restate these procedures here.** Start at
[`third_party/ANTfrastructure/docs/INDEX.md`](third_party/ANTfrastructure/docs/INDEX.md),
which maps topic → owning document, so these links survive upstream
reorganisation.

| Topic | Where |
| --- | --- |
| Wiring this repo to ANTfrastructure — resolver, actions, libraries | `docs/adopting-in-a-new-project.md` |
| Linux container builds | `docs/linux-build-basics.md` |
| Cross-compilation chain and its failure classes | `docs/linux-cross-builds.md`, `docs/cross-build-verification.md` |
| The Windows image, its entrypoint and known traps | `docs/windows-builds.md` |
| The Windows arm64 cross lane: the arm64 bundle, the arch gate, the `windows-11-arm` run job, why Release, Profile and the Debug (ASan) build | `docs/windows-cross-builds.md` |
| The riscv64 cross lane: the sysroot from the image's riscv64 child, the cross clang, QEMU binfmt, what cannot run under QEMU | `docs/riscv64-cross-test-lanes.md` |
| ONNX Runtime's one source (the chain build) and the G6 census | `docs/onnxruntime-single-source.md` |
| Bind mount vs tar-pipe, Dev Drive filter setup, container reuse | `docs/windows-container-build-performance.md` |
| sccache across build hosts: the host's dufs plus a shared S3 bucket, the key as BuildKit secrets or by name on a reused container's `docker exec`, and the fallback when the bucket stalls; the bucket's server runbook | `docs/windows-build-resources.md` § *Two cache levels*, `linux/sccache-s3/README.md` |
| clang-format / clang-tidy / cmake-format and the canonical configs | `docs/code-quality-tooling.md` |
| Job counts, per-job memory, why a build got OOM-killed | `docs/build-parallelism-memory-tuning.md` |
| The five shell-safety bug classes | `third_party/ANTfrastructure/AGENTS.md` § *Shell safety conventions* |
| Code comments: one line, only the why; API docs short; gated | `third_party/ANTfrastructure/AGENTS.md` § *Comments: one line, only the why* |
| Searching the tree: `rg`, not `grep -r` | `third_party/ANTfrastructure/AGENTS.md` § *Searching the tree: ripgrep (`rg`)* |

**These scripts are wrappers, not implementations**: change behaviour upstream, not here.

| Script | Upstream driver |
| --- | --- |
| `scripts/linux/ci-common.sh` | sources `linux/scripts/01-core/` (logging, retry, downloads, parallelism) |
| `scripts/linux/ci-coverage.sh` | `linux/scripts/lib/coverage.sh`: gcovr for GCC, llvm-cov for clang |
| `scripts/linux/run-static-analysis-format.sh` | `linux/scripts/lib/code-quality.sh`; every analysis runs through `01-core/gates.sh` (`run_gate` … `assert_gates`) with its tools `require_tools`'d, never skipped: no tool, no green lane (the file header names the rule and its owner) |
| `scripts/linux/ci-build-and-test.sh` | `linux/scripts/lib/cmake-build.sh` + `linux/scripts/lib/ctest-run.sh` |
| `scripts/linux/ci-profile-bench.sh` | `linux/scripts/lib/cmake-build.sh`; the perf/benchmark run itself stays local |
| `scripts/linux/renovate-local.sh` | `linux/scripts/renovate-local.sh`: Renovate as a local CLI, plus the git half that applies what it can only detect (passes this repo's root) |
| `scripts/linux/ci-docs.sh` | `linux/scripts/lib/docs-build.sh`, its steps called one by one so the test-result pages `junit_to_markdown.py` renders exist before Sphinx reads them |
| `scripts/linux/ci-release.sh` | `linux/scripts/lib/cmake-build.sh` (configure through `cmake_build_main`) + `lib/app-packaging.sh` (the flatpak); `load_project_metadata` and `ensure_flatpak_tools` stay local |
| `scripts/linux/ci-finalize.sh` | `linux/scripts/01-core/bind-mount-ownership.sh`'s `fix_bind_mount_ownership` |
| `scripts/linux/run-lint-gates.sh` | `linux/scripts/run-lint-gates.sh` over this repo's root, always with `--ratchets` as CI passes it; the freeze files (`comment-size.allow`, `shellcheck-warnings.allow`, `doc-dupes-hub.allow`) sit at the repo root. What each gate does: [`code-quality-tooling.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/code-quality-tooling.md) |

CI uses ANTfrastructure's composite actions (`prepare-linux-ci-host`, `run-in-linux-container`,
`compiler-cache-restore`/`-save`, `clean-host-package-check`, `requested-lanes`,
`run-pester-suite`) and reusable workflows (`container-ci-windows.yml`, `container-ci-riscv64.yml`,
`build-docs.yml`, `release-publish.yml`, `lint-gates.yml`, `submodule-pins.yml`), not hand-written
`docker run` blocks.

**CMake modules: this repo's `cmake/` first, then the hub's.** `CMakeLists.txt` puts this repo's
`cmake/` ahead of `third_party/ANTfrastructure/cmake/` on `CMAKE_MODULE_PATH` and includes every
module by name, so a local module of the same name wins. Local `cmake/` holds only this project's own policy (`ProjectOptions.cmake`,
`CPackOptions.cmake`, `SystemLibDependencies.cmake`, `MsvcRuntime.cmake`, `fuzztest_compat/`);
everything else, `Test/cmake/CommonTestBuild.cmake`'s GoogleTest registration (`GTestDiscovery`)
included, resolves by name from
[`third_party/ANTfrastructure/cmake`](third_party/ANTfrastructure/cmake/README.md).

Two upstream facts repeated here only because they bite before you reach a doc:

- Every ANTfrastructure PowerShell module declares `#requires -Version 7.0`, so the
  Windows entry scripts do too — launch with `pwsh`, never `powershell`. Under
  5.1 it fails as an opaque `Import-Module` error.
- Composite actions resolve at `@develop`, so a ANTfrastructure change a workflow
  depends on must be pushed **before** the consumer change.

**This repo's glue:** `scripts/windows/Resolve-BuildModule.ps1` and its bash twin
`scripts/linux/lib/antfrastructure.sh`, which find the submodule
([`adopting-in-a-new-project.md` § 1](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/adopting-in-a-new-project.md#1-the-one-file-that-cannot-live-here)).
Both are body-mode copies of the hub's templates
([`shared/config/README.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/shared/config/README.md#the-template-trees-are-owners-too)):
change the template upstream, then copy it. Unlike CMake, PowerShell resolves a module from the
hub first, then from `scripts/windows/modules/`, which this repo does not have. How
`Build-Windows.ps1` imports its modules is the hub's calling convention,
[`adopting-in-a-new-project.md` § 8](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/adopting-in-a-new-project.md#8-calling-conventions-what-every-consumer-looks-like)
and its
[*Reach for these before writing a helper*](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/adopting-in-a-new-project.md#reach-for-these-before-writing-a-helper).

## 3. Critical invariant: submodule pins

Builds are only supported against the **recorded submodule gitlinks**, the commits CI builds
green. `git submodule update --checkout --recursive` restores every pin. If a drifted submodule
is what you want, update the gitlink **and** fix the fallout in the same change.

- The abseil `FetchContent` pin in `third_party/CMakeLists.txt` must stay **at or above** the
  `absl_TAG` that `third_party/FUZZTEST/cmake/BuildDependencies.cmake` pins: this declaration comes
  first and wins, and an older Abseil lacks targets FuzzTest links (e.g.
  `absl::random_mocking_access`). Moving abseil up is safe for that constraint, as
  BeschleunigerBallett's identical pair already documents; moving FUZZTEST up may raise the floor.
  `cmake/fuzztest_compat/` papers over the header gap between the current pair; re-check it on
  every move of either. Measured 2026-10-07: abseil 20260817.0 against FuzzTest 2026-06-29 (which
  pins 20260526.0) passes the clang Debug suites (ASan + UBSan), `fuzzTestSuite`, the TSan build
  and the GCC suites in `:latest`.
- `third_party/ANTfrastructure`'s **own** nested submodule is a build input here.
  `requirements.txt` installs the family's Sphinx theme, which `docs/source/conf.py` calls
  (`setup_theme()`), from
  `third_party/ANTfrastructure/third_party/DocumANTation/sphinx-kataglyphis-theme`, so the site is
  pinned to the DocumANTation commit the ANTfrastructure gitlink carries. `git submodule update
  --init` without `--recursive` satisfies every other consumer here and breaks this one (the
  symptom: § 4).
- No other pin here has a recorded coupling (checked 2026-09-15).

Drift is guarded by ANTfrastructure's shared suite, which `.github/workflows/submodule-pins.yml`
runs on every push and PR that touches `.gitmodules` or `third_party/**`. It asserts that every
configured submodule is checked out, sits at its recorded commit and is pinned to a commit a fresh
clone could restore: a pin on no remote branch works only on the machine that made it. Its
checkout needs `submodules: true`; without it the suite FAILS rather than passing on an empty
tree. Run it after any pin bump. It does **not** check the couplings above; that is on you.

## 4. Pitfalls specific to this project

Everything here is false or meaningless in another repo — that is why it is
written out rather than linked.

- **clang-tidy is skipped for GCC on purpose.** A GCC-generated `compile_commands.json` carries
  C++ module flags clang-tidy cannot parse, so `run-static-analysis-format.sh` runs it (and
  scan-build) only when `COMPILER=clang`. Re-enabling it produces a wall of parse errors, not
  findings.
- **Two analyses stay local rather than going upstream:** `scan-build` (the pinned LLVM's), which
  the clang lane runs, and `clang++ --analyze` with the `-DUSE_RUST=1` define it needs, which runs
  only under `--direct-analyze` (no lane passes it). No other ANTfrastructure consumer runs them,
  and one consumer does not justify moving code upstream (the two-consumer rule).
- **`.ixx` files are first-class sources.** Tooling that globs C++ sources must include them; the
  shared `.pre-commit-config.yaml` regex upstream was extended for exactly this. A file-discovery
  change that drops `.ixx` silently shrinks the format and tidy sets instead of failing.
- **The C API is the ABI surface.** `Src/kataglyphis_c_api.{h,ixx,cpp}` and `kataglyphis_export.h`
  are what the native plugin links against: today one function, `kataglyphis_add`, which the
  Windows plugin reaches through the header and the Linux plugin through
  `import kataglyphis.c_api;`. The webcam path's `knt_push_frame` is not part of it; the plugin
  defines and exports that itself. A signature change here breaks a consumer one superproject up,
  which no build in this repo catches.
- **The docs theme comes from DocumANTation, via ANTfrastructure** (§ 3). A docs venv whose
  install stops at `error: Distribution not found at: file:///…/sphinx-kataglyphis-theme` means
  the nested submodule was not initialised recursively, or `uv pip install -r requirements.txt`
  ran outside the repo root: uv resolves the `-e` path from the working directory. The theme needs
  Python 3.14. `conf.py` adds only this project's settings to `setup_theme()`: graphviz,
  inheritance diagrams, breathe and exhale when Doxygen's XML exists, the version from
  `CMakeLists.txt`, and an `include-read` hook that points exhale's two tree views at the ids
  docutils gives its labels (lowercase, no dots), where their links used to miss 77 anchors.
- **One binary is tracked on purpose; models never are.** `images/Engine_logo.bmp` (117 KiB, the
  family's ant) is the NSIS installer header image (`cmake/CPackOptions.cmake`), which CPack reads
  as a literal path at package time. It **stays**, and no LFS is introduced. The family's history
  rewrite of 2026-10-17
  ([`data-repositories.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/data-repositories.md#what-moved-and-why))
  took this pack from 12 to 2 MiB. The AGPL-3.0 `models/yolo26n.onnx` (9.5 MiB) left the tree on
  2026-10-14 (owner): `Src/inference_demo.cpp` and `resources/configs/inference_config.toml` now
  name `models/deim_dfine_n_coco.onnx` (Apache-2.0), from
  [ModelANT](https://github.com/Kataglyphis/ModelANT)'s release. `models/models.lock` pins it and
  its license and notice by SHA-256, and the hub's `fetch-data-lock.py` fetches them
  (`models/README.md`); no other fetcher exists here. No `Test/` suite loads it.
  `.gitignore` carries `*.onnx` with no exception, everything in `models/` but the README and the
  lock, and `*.bmp` with the logo re-included, so a model or bitmap dropped here is not committed
  unnoticed, and the hub's large-files gate
  (`--ratchets`) fails any tracked data file over 500 KiB; no `large-files.allow` exists, so none
  is frozen.
- **Dependency upgrades are Renovate as a local CLI, and nothing else**
  ([`dependency-updates.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/dependency-updates.md):
  why local, run it from WSL, what `--apply` writes, `GITHUB_COM_TOKEN`). This repo has no
  `.github/dependabot.yml`, so the wrapper is its only dependency watch, and nothing runs it for you.

  ```bash
  bash scripts/linux/renovate-local.sh                     # report (default: every manager this tree has)
  bash scripts/linux/renovate-local.sh --managers pep621   # the pyproject pins
  bash scripts/linux/renovate-local.sh --managers custom.regex  # the CMake pins in third_party/CMakeLists.txt
  bash scripts/linux/renovate-local.sh --apply --dry-run   # the plan
  bash scripts/linux/renovate-local.sh --apply             # gitlinks, manifests and their locks
  ```

  - All seven `.gitmodules` entries declare a `branch =` since ff4e867, so `--apply` moves every
    gitlink that is behind, `FUZZTEST` included, which may raise the abseil pin's floor (§ 3).
  - The CMake pins come from the hub preset's `custom.regex` managers, which tree detection never
    picks: name them, as above.
- **ONNX Runtime is REQUIRED and must be the family's chain build** (owner rule 2026-09-23).
  `cmake/SystemLibDependencies.cmake` searches exactly one prefix (`-DONNXRUNTIME_ROOT`, else the
  image's `ONNX_ROOT` on Windows or `/usr/local/lib/onnxruntime-cpu` on Linux) and refuses a
  runtime library that does not embed the chain's ORT source root, so a host without the image's
  ORT fails at configure time, by design. Do not add back a fallback path, a pkg-config probe or a
  "download it" hint; point `ONNXRUNTIME_ROOT` at a chain-built prefix. What ships goes through
  ANTfrastructure's G6 census, through the hub's `Assert-ChainOrtTree` (`WindowsOrtPayload.Common`):
  - every `bin\` the Windows lane stages (hub `Copy-MediaRuntimeBundle`);
  - the release install tree the NSIS/WiX/ZIP installers pack: the same CMake file installs the
    proven `onnxruntime.dll` and its companions into `bin\`, and the lane proves a
    `cmake --install` of it before `--target package`;
  - the MSIX payload;
  - the Python package (`Build-PythonBindings.ps1`, the chain layout only), staged with
    `Copy-ChainOrtBeside -All`.

  The census wants every ORT binary to be the image's chain build, byte for byte,
  `onnxruntime.dll` beside the exe (or in the package's `_libs`), and no ORT-family DLL that the
  chain ORT or GenAI install has not got. `Build-Windows.ps1` and `Build-PythonBindings.ps1` stop,
  naming the hub commit, while the pinned hub predates that module.
- **Presets are per-compiler and per-sanitizer**, not a single matrix:
  `linux-{debug,profile,RelWithDebInfo,release}-{clang,GNU}`, `linux-debug-clang-tsan`, and on
  Windows `x64-{ClangCL,Clang}-Windows-{Debug,RelWithDebInfo,Profile,Release}` plus
  `x64-MSVC-Windows-{Debug,Release}`. Coverage requires a matching compiler: gcovr only reads GCC
  output, llvm-cov only clang.
- **llvm-cov coverage is `linux-debug-clang`'s, one profile per process.**
  `myproject_ENABLE_COVERAGE` defaults OFF (since 2ace55e), so that preset sets it ON;
  `linux-debug-clang-tsan` inherits `linux-clang`, not that preset, and stays uninstrumented.
  `gtest_discover_tests` runs every test case as its own process, so `ci-build-and-test.sh` points
  `LLVM_PROFILE_FILE` at `<build>/profraw/%p.profraw` (emptied first) for the ctest and fuzz runs,
  and `ci-coverage.sh` merges every file there into one indexed profile before the hub's
  `coverage_llvm_report`, which takes ONE profile path and ONE object. The object is
  `lib/libAccelerANTgine.so`, where `Src/` lives; a test executable's own mapping holds only
  `Test/`, which the ignore regex drops. Until 2026-10-01 every `Src/` file read 0.00% because
  the suites were placeholders; they call the library now
  (`docs/source/development_workflow.rst` § *The Suites*). Since then `linux-debug-GNU` sets the
  option too, so gcovr measures the GCC lane, where it reported `0 out of 0` lines before.
  `inference_demo.cpp` read 0% while it was a `main` compiled into the library that nothing
  called; since 2026-10-15 it is the `AccelerANTgine_demo` program, outside the library's figure.
- **The tests generate their ONNX models.** `Test/common/kataglyphis_test_support.h` hand-encodes
  a ModelProto (IR 8, opset 13): Relu, Add, Relu plus Neg, and a Reshape from `images[1,3,H,W]` to
  `output[1,rows,values]`. With the Reshape a test writes the raw detector output as the input
  image, so the YOLO decoder runs end to end without any model file. Nothing is staged for the
  Windows arm64 run job, and the `*.onnx` guard in `.gitignore` stays as it is. The shipped
  `resources/configs/inference_config.toml` is compiled into the suites
  (`kataglyphis_embed_text_file`) for the same reason.
- **A GStreamer test skips when an element is missing; Windows stages four plugins.**
  `KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS` probes through the library and names the missing
  element in its `GTEST_SKIP`. GStreamer looks for plugins in the directory of
  `gstreamer-1.0-0.dll`, minus a trailing `bin`, plus `lib\gstreamer-1.0`. That DLL sits in
  `build-*\bin`, so `Copy-ImageGStreamerTestPlugins` copies coreelements, app, videotestsrc and
  videoconvertscale from the image into `build-*\lib\gstreamer-1.0` for the Debug and Profile
  trees. The staged Release suites (`dist\windows-<arch>-tests`, a flat directory) get them in
  their own `lib\gstreamer-1.0`, with the plugins' imports beside the suites; the hub's import
  walk resolves a name anywhere in the tree. The WebRTC tests need `webrtcsink`
  (gst-plugins-rs), which only the Linux image has.
- **On Linux no test may skip, and UBSan is fatal** (2026-10-15). ctest counts a gtest
  `[  SKIPPED ]` as passed in its "100% tests passed" line, so `ci-build-and-test.sh` fails the
  lane on any `<skipped>` in its JUnit file and names the tests: the image carries every element,
  so a skip there means one went missing. Windows keeps its skips (`webrtcsink`). The Debug
  presets build UBSan recoverable, so the same script exports `UBSAN_OPTIONS=halt_on_error=1`; a
  report used to print and the test still passed.
- **On clang-cl the fuzz suite is built without sanitizers.** absl's swisstable layout depends on
  ASan (`ABSL_SWISSTABLE_ENABLE_GENERATIONS`), and clang-cl applies ASan only through
  `myproject_options`, so absl and FuzzTest were not instrumented there while the suite was. Its
  absl COMDATs then won over absl's own and crashed a static initialiser (`FLAGS_nofuzz`, run
  36913668933); a Linux probe with the mismatch the other way round crashed in
  `CommonFieldsGenerationInfoEnabled::generation()`. Linux keeps ASan on the suite, because there
  `-fsanitize=address` is global and absl is instrumented too. Importing the ASan-built module
  BMIs from the unsanitized suite compiles: clang treats sanitizer differences as compatible.
- **The TSan run ignores uninstrumented modules.** GLib, GStreamer and ONNX Runtime hand memory
  between threads through futex locks TSan cannot see, so `ci-build-and-test.sh` sets
  `TSAN_OPTIONS=ignore_noninstrumented_modules=1` for the TSan ctest; our code is instrumented and
  still reports. Its first run found two real teardown races: `VideoDetectorPipeline` destroyed
  its callbacks before stopping the stream that calls them, and the tests' `EventCounter` notified
  after unlocking. `GStreamerPipeline` now takes its callback mutex after every NULL state change,
  which makes the ordering GLib's thread join provides visible to TSan. Without `--privileged`
  TSan dies at start (`unable to disable ASLR`); the CI container has it.
- **`-RunWebRtcSmoke` stays opt-in on Windows.** The Windows image has no gst-plugins-rs, so
  neither `webrtcsink` nor `gst-webrtc-signalling-server`: the hub's mandatory plugin list carries
  `webrtcbin` only (checked 2026-10-01). The smoke also runs on the runner host, which has
  neither. Linux covers the path: `ci-profile-bench.sh` streams the CLI against the image's
  signalling server, and the commit suite starts a stream against a refusing one.
- **On Windows the suites find their DLLs through `ENVIRONMENT_MODIFICATION`.** clang-cl
  registers each suite as one ctest test through the hub's `add_test` fallback
  (`GTestDiscovery.cmake`), whose `ENVIRONMENT "PATH=<exe dir>;<build>/bin;..."` is a CMake list:
  ctest splits it at those semicolons and the test runs with `PATH=<exe dir>` alone (measured with
  a probe project). The placeholder suites never noticed, because they imported nothing from
  `AccelerANTgine.dll`; the real ones died with `0xc0000135`.
  `kataglyphis_configure_gtest_discovery` prepends `bin\` and appends the compiler's directory
  through `ENVIRONMENT_MODIFICATION` until the hub fixes it. `Build-Windows.ps1` runs the Profile
  benchmarks with `bin\` on `PATH` for the same reason. On the runner host `PATH` is not enough
  for ONNX Runtime: the loader looks in System32 before `PATH`, and a desktop Windows has Windows
  ML's `onnxruntime.dll` 1.17 there, so every ORT test died with
  `requested API version [30] is not available` (run 36921988802). The Debug and Profile trees
  therefore also get the chain ORT beside the suites at the build root (`Copy-ChainOrtBeside`), as
  the staged Release suites already have it.
- **Every ctest run refuses an empty tree.** The Linux scripts pass `--no-tests=error`;
  `Build-Windows.ps1` sets `CTEST_NO_TESTS_ACTION=error`, because the hub's
  `Invoke-CtestDiscoveredTests` takes no extra ctest arguments.
- **Every LLVM tool that reads clang's output must be the compiler's own.**
  - Linux: the image's `clang-tidy`, `llvm-profdata`, `llvm-cov` and the rest on PATH are clang's
    LLVM 23 (hub CON15, `:latest` of 2026-09-29), so `ci-coverage.sh` and
    `run-static-analysis-format.sh` call them by bare name. An older image put Ubuntu's LLVM 21
    there, which refuses clang 23's raw profile format 11 (`no profile can be merged`) and its
    module PCMs (`module file … uses a newer format that cannot be read`); should either message
    come back, it is an image regression, not something to paper over here again.
  - `clang-format` is the pinned release too since hub CON71. The Linux format gate in
    `run-static-analysis-format.sh` fails on any other version, because releases format
    differently: 21.1.8 flags 7 of the 39 files that 23.1.3 passes.
  - The same image's bare `clang`/`clang++` select its GCC 16.2 by themselves
    ([`linux-cross-builds.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/linux-cross-builds.md#clang-cross-wrappers)),
    so nothing here injects `--gcc-toolchain`; the cxx crate's `cc` build passes
    `--target=<native triple>`, which loads the same config file.
  - Windows has the same trap with a different pair. The image compiles with its patched LLVM
    (`C:/llvm-patched/bin/clang-cl.exe`), so the `clang-tidy` on PATH is scoop's, and it refuses
    the BMIs with `module file … built from a different branch () than the compiler`.
    `Build-Windows.ps1`'s clang-tidy step reads `CMAKE_CXX_COMPILER` from the build's
    `CMakeCache.txt` and uses the `clang-tidy.exe` beside it. The image ships one since hub CON10
    (2026-10-01), and it reads clang-cl C++23 BMIs, so the step sets `ModuleImportPattern` to
    `'(?!)'` and analyses every `Src/` TU, module importers included. A compiler with no sibling
    tidy keeps the broad BMI skip, because the PATH tidy cannot read them.
- **Both module targets are PIC, and must stay so.** `nlohmann_json_modules` and
  `tomlplusplus_modules` (`third_party/CMakeLists.txt`) are static libraries linked into the
  SHARED `libAccelerANTgine`, and GCC writes the TLS model of a template instantiated inside a
  module into the CMI. Built without `-fPIC`, `json.cppm` gives `basic_json<>::nesting_depth()`'s
  `static thread_local` local-exec, and every `-fPIC` importer inherits it: x86-64 then fails the
  link with `R_X86_64_TPOFF32 … local-exec is incompatible with -shared`, while aarch64 links
  `R_AARCH64_TLSLE_*` into the `.so` without a word. Treat PIC like `-pthread` and
  `-fno-exceptions` there: a BMI flag the importer must agree with. clang is not affected.
- **perf is optional in `ci-profile-bench.sh`, CI cannot open perf events, and perf alone is not
  a profile.**
  - The image has perf (`linux-perf` 7.0.0-38.38, `perf version 7.0.14`, checked in `:latest`
    2026-10-19). Before it did, a bare `timeout … perf record` died with exit 127, since Ubuntu
    26.04's `linux-tools-common` no longer ships `/usr/bin/perf`.
  - CI still records nothing. The lane runs as the image's uid 1001, which has no capabilities
    even under `--privileged` (`CapEff` 0), and the GitHub runners set `perf_event_paranoid` to 4,
    so the probe exits 255 on every Linux leg (x64 run 39135484490, 2026-10-18; arm64 run
    38756495381, 2026-10-15). A host at paranoid 2, such as WSL2's 6.18 kernel, records
    unprivileged. A CI perf profile now needs permission, not a package: root or `CAP_PERFMON` in
    the container, or a lower `perf_event_paranoid` on the runner.
  - The script probes `perf record` (same options) around `true`. Where that fails it WARNs with
    perf's own message, records nothing, and still runs the workload for a `--smoke-seconds`
    window (10 s) without a recorder, so a workload that stops streaming early fails the lane
    either way; then the benchmark suite. Where the probe passes, everything but the
    window-closing exit 124 stays fatal.
  - The workload, `bin/AccelerANTgine --webrtc --source test`, is a WebRTC producer. With no
    signalling server on its URI it gets `Connection refused`, its loop breaks on
    `StreamState::Error` and it returns 0 about 200 ms in (measured with `linux-perf` installed in
    a `--privileged` image container, which is how CI runs). So unless `--profile-args` names its
    own `--server`, the script starts the image's `gst-webrtc-signalling-server` on
    `127.0.0.1:18443` (`--signalling-port`; not the CLI's default 8443, which a dev box's own
    producer holds) for the window and points the CLI at it. With no consumer attached the
    producer mostly idles: 150 to 230 samples in a 20 s window were measured, not a hot loop.

- **The Python module runs without the GIL on 3.14t, so its locks are load-bearing.**
  `nanobind_add_module(... FREE_THREADED ...)` marks it `Py_MOD_GIL_NOT_USED`; against a GIL
  Python nanobind ignores the flag. On Linux `ci-python-bindings.sh` ships a `cp314` and a
  `cp314t` wheel, and the hub's `free-threaded-wheel.py prove` fails the lane when the second
  re-enables the GIL. The flag is only safe because of three locks:
  - `OnnxInferenceEngine` and `YoloDetector` each hold a `std::shared_mutex`, shared by runs and
    taken alone by `initialize`;
  - every bound field takes `nb::lock_self()`;
  - binding code copies Python arguments before it releases the GIL.

  A new bound class with mutable state needs the same. `Test/python/test_threading.py` crashes
  without them, on the GIL wheel too, because the runs release the GIL.

- **The Linux packages carry the image's own GStreamer, never the distro's** (owner, 2026-10-17;
  the mechanism is the hub's
  [`linux-build-basics.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/linux-build-basics.md#gstreamer-loads-from-the-package-alone)).
  `cmake/CPackOptions.cmake` installs the plugins the pipelines and `webrtcsink` load into
  `lib/accelerantgine/gstreamer-1.0`, with openh264 and libcamerasrc when the image has them and
  NSS's softokn and freebl beside `libnss3`; the `.deb` depends on glibc and EGL alone, which the
  arm64 libcamera plugin links. `Src/bundled_gstreamer.cpp` sets the environment at load, looking
  beside the library (embedded) and in `accelerantgine/` under it (this package, whose
  `libAccelerANTgine.so` sits in `lib/`). `AccelerANTgine --gst_check` prints each element's
  plugin file and fails on a missing one, or in a package on one loaded from outside it; the
  clean-host jobs run it on a bare Ubuntu. A new element in a pipeline goes into
  `locate_elements()`, its plugin into the list. Embedded in OmniAccelerANT's plugin, none of this
  installs: that bundle carries its own.

## 5. Build, run, test

The whole Linux CI chain, in order:

```bash
bash scripts/linux/ci-run-all.sh
```

runs `ci-init.sh` → `ci-build-and-test.sh` → `ci-coverage.sh` →
`run-static-analysis-format.sh` → `ci-profile-bench.sh` → `ci-python-bindings.sh`
(clang only) → `ci-docs.sh` → `ci-release.sh` → `ci-finalize.sh`. Each runs on its own with the
arguments `ci-run-all.sh` passes it.

**The pre-commit hook** installs from `requirements.txt` into a `uv` venv; the commands are in
`docs/source/development_workflow.rst` § *Static Analysis And Formatting*.

Windows:

```powershell
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
pwsh -NoProfile -File .\scripts\windows\Build-PythonBindings.ps1
```

`Start-Windows.ps1 -Config Debug|Profile|Release` runs on the host what a build produced: the CLI
check, then that configuration's suites. One script replaced three that differed only in a build
directory and a suite list; it reads the build directory from `Build-Windows.config.psd1`, the
table `Build-Windows.ps1` builds into, so producer and consumer cannot disagree.

`Invoke-ContainerBuild.ps1`, `Invoke-ContainerPythonBindings.ps1` and `Show-BuildHelp.ps1` are
the other entry points, named for what they do: none of them starts the application. The first
two run their `Build-*.ps1` in the ANTfrastructure Windows image through the hub's
`Invoke-RepoContainerBuild.ps1`, which owns the plumbing (`WindowsContainerBuild.Reuse` +
`WindowsContainerImage.Common`, the image ref from `versions.env`): tar-pipe transport into a
reusable per-lane build container at `C:\ws` by default, `-UseBindMount` to opt into a bind
mount, `-FreshContainer` to reset, `-WhatIf` to print the assembled in-container command without
building. Build output goes to the console and `logs/`; the old root-level `build*.log` redirect
files are gone, and so is the image-baked `C:\workspace` mount target (mounting over an image dir
fails at CreateComputeSystem on host/image OS-build skew).

**CI lanes** follow the owner's fleet convention of 2026-09-24: kebab-case files, one file per
platform + arch, display names `<Platform> <Arch> · <what>`. They are `linux-x64.yml` and
`linux-arm64.yml` (each calls the containerized `reusable-linux.yml` once per compiler),
`windows-x64.yml` (the container build through the hub's `container-ci-windows.yml`, a
`lint-powershell` job over `scripts/` with the hub's `Invoke-Lint.ps1`, and a `pester-tests` job
over `scripts/windows/tests/` plus the hub's `shared/windows/tests/Repo.GeneratedArtifacts.Tests.ps1`), `windows-arm64-cross.yml`, `linux-riscv64.yml`, `lint-gates.yml`
and `submodule-pins.yml`.

- **A push or PR runs Linux x64 and the gates; the other four platform lanes run on request**: the
  family's rule (owner, 2026-10-15), with the tokens, the hand start and the merge into `main`, is
  [`branch-and-release-strategy.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/branch-and-release-strategy.md).
  Here `[ci windows]` runs `windows-x64` and `windows-arm64-cross`, `[ci arm64]` `linux-arm64`
  and `windows-arm64-cross`, `[ci riscv64]` `linux-riscv64`, and `[ci all]` all four. A lane's
  README badge shows only its runs started by hand; a requested run is listed under *On request*.
- **Every push to `main` is a release** (`release.yml`): all five lanes once more, then
  `v<version>` with every lane's packages. The version check and the release job are two calls
  of the hub's `release-publish.yml`
  ([§ *The reusable release workflow*](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/branch-and-release-strategy.md#the-reusable-release-workflow));
  the release job's `collect:` options pick CPack's packages and the wheels, never a file from a
  `bundle/`, and the hub's collector suite runs them over uploads shaped like this repo's. The
  version is `CMakeLists.txt`'s `project()` `VERSION`.
  `gh workflow run release.yml --ref develop -f dry-run=true` proves it on `develop`.
- **The docs site** goes through the hub's `build-docs.yml` (2026-10-19). The clang x64 build's
  `ci-docs.sh` writes it with the coverage pages, `reusable-linux.yml` uploads `docs/build/html/`
  as `accelerantgine-docs-site`, and `linux-x64.yml`'s `docs` job hands that to the hub, which adds
  its `.htaccess` and 404 page, fails on a dead internal link or anchor, and publishes only on a
  push to `develop` or `main` (`SERVER`/`USERNAME`/`PW` mapped onto its `FTP_*`). A pull request
  builds and checks the site but publishes nothing.
  [`docs-sites.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/docs-sites.md#the-reusable-workflow)
  has the rest.
- Every job that owns a runner carries `timeout-minutes`, every workflow declares `permissions:`,
  and every upload sets `if-no-files-found: error`: the hub's workflow conventions
  (`verify_workflow_conventions.py`), measured at zero findings here since the rename (again on
  2026-09-25).

**Both Windows lanes call the hub's reusable `container-ci-windows.yml`** (the family's
thin-caller step, 2026-09-25, after OxidANT's).

- `windows-x64.yml` runs `Build-Windows.ps1 -WorkspaceDir C:\ws -BuildTargets clangcl-debug,clangcl-profile,clangcl-release -StageTests`
  in the family image, on the hub's bind mount (`D:\ws` → `C:\ws`); `Invoke-ContainerBuild.ps1`'s
  tar-pipe stays the local entry point. Its `host-command` runs `Start-Windows.ps1` for each
  configuration on the runner host, which has the desktop the container lacks. `-Config Release`
  runs the suites `-StageTests` built in Release, from `dist\windows-x64-tests`, through the same
  `Invoke-StagedTests.ps1` the arm64 run job uses, and fails on a failed or an empty verdict.
  `dist/windows-x64` then uploads as `AccelerANTgine-windows-x64`.
- `windows-arm64-cross.yml` (owner decision 2026-09-25) is one `uses:` onto the same workflow. It
  runs `Build-Windows.ps1 -TargetArch arm64 -BuildTargets clangcl-release,clangcl-debug -SkipFormat`
  in the family image's arm64 bundle (the format steps are the x64 lane's: they read the source,
  not the target). The hub's arch gate then grades `dist/windows-arm64`, and `windows-11-arm`
  runs `bundle/bin/AccelerANTgine.exe`. The image's runtime bundle as a whole is not this lane's
  to gate: since hub eb7a05bb the hub proves it in its own `windows-arm64.yml`, and
  `container-ci-windows.yml` no longer takes `bundle-artifact-name`.

On a cross build `Build-Windows.ps1`:

- refuses every target but clangcl-release and clangcl-debug, before the log opens. Debug's
  aarch64 ASan runtime exists since 2026-10-03 (VS 2026's toolset, the hub's Sanitizers.cmake
  picks it by CMAKE_SYSTEM_PROCESSOR); Profile runs benchmarks and PGO, which stay host-only;
- stages the Debug (ASan) suite as `commitTestSuite-debug.exe` with Microsoft's aarch64 ASan
  runtime beside it; the runner supplies the /MDd debug CRT and ucrtbased.dll from its own VS
  and SDK, since neither is redistributable;
- configures with the hub's `Get-CrossConfigureArgs -Corrosion`;
- builds into `build-clangcl-release-arm64`;
- ships the `aarch64` MSI and ZIP (not NSIS: its installer stub is x86) and the arm64 MSIX,
  whose manifest takes `__ARCH__`;
- with `-StageTests`, which the lane passes, builds the commit, compile, fuzz and perf suites
  in Release (`KATAGLYPHIS_RELEASE_TESTS`) and stages them with their DLL closure, the hub's
  `Invoke-StagedTests.ps1` and a `tests.json` in `dist\windows-arm64-tests`. The three gtest
  binaries count by their summaries, the benchmarks by exit code
  (`--benchmark_min_time=0.05s`). That Release tree is also the packaged one, so the suites
  must install nothing: FuzzTest is added `EXCLUDE_FROM_ALL`, which drops its install rules
  (ANTLR's names a runtime nobody builds, and `cmake --install` died on it), and gtest gets
  `INSTALL_GTEST OFF`. Measured on Linux: the install trees with and without the suites are
  the same five files.

**Both arches ship the same product (owner decision 2026-09-25: x64 was thinner).**
clangcl-release configures `KATAGLYPHIS_PACKAGE_DLL_DIR`, the hub's
`kataglyphis_install_package_dlls`, and fills it after the build with `Copy-PeImportClosure` over
`AccelerANTgine.exe` and `AccelerANTgine.dll`. The search runs in the order of
`Get-ProductDllSearchPath`: the chain ONNX Runtime, the image's `C:\runtime\bin`, then the
target's VC++ runtime. The CPack installers and the portable bundle in
`dist/windows-<x64|arm64>/bundle` carry that closure, and G6 proves the ORT in each. The MSIX
ships the bundle's `bin\` whole. On x64 the NSIS installer joins the MSI and ZIP in
`dist/windows-x64/packages`; arm64 leaves it out, because its installer stub is x86. The MSIX is
signed through the hub's `Invoke-MsixPackage -Sign -SigningRoot` with the first `*.pfx` at the
repository root and `MSIX_PFX_PASSWORD`; with no `.pfx` there the step warns and the package
stays unsigned.

`Build-Windows.ps1` exits 1 on an error outside every build step; it used to log it and exit 0.

`lint-gates.yml` and `submodule-pins.yml` are one `uses:` line each onto ANTfrastructure's
reusable workflows; only this repo's `on:` filters and their inputs (`ratchets: true` for the
lint gates, `pester-version: '3.4.0'` for the pins) stay local.
`lint-gates.yml` runs the same aggregator a dev box runs with
`bash scripts/linux/run-lint-gates.sh` (which adds `--ratchets` itself), against the same
explicit root, but reaches it from the hub checkout rather than through the wrapper, because the
wrappers sit at different paths across the family.

### The riscv64 lane

**Cross-built on amd64, tested under QEMU**: the family's riscv64 lane
([`riscv64-cross-test-lanes.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/riscv64-cross-test-lanes.md)).
`linux-riscv64.yml` ("Linux riscv64 · cross build + test") is one `uses:` onto the hub's
`container-ci-riscv64.yml`, whose container half is `bash scripts/linux/ci-riscv64-test.sh`: the
hub's `riscv64_cross_env`, then the `linux-riscv64-cross` preset (Debug,
`Rust_CARGO_TARGET=riscv64gc-unknown-linux-gnu`), ctest, and `fuzzTestSuite`.

- **What runs:** the native Debug suites: every ctest entry of the commit, compile and fuzz
  suites, then `fuzzTestSuite` once more as a whole, against the image's riscv64 GStreamer and
  ONNX Runtime. Measured 2026-10-01 with the placeholder suites: 2 min 7 s end to end on a warm
  cargo home.
- **What does not:** ASan/UBSan, coverage and the TSan build. The cross clang (the image's
  distro clang 22; the image's own clang 23 is X86-only) has no riscv64 compiler-rt, so the
  preset turns them off; the x64 and arm64 lanes keep them. No perf suite: timing under QEMU
  measures QEMU.
- **Locally:** the hub page has the sysroot and container commands.

## 6. Docs owned by this repo

**Write docs like a developer: short and precise** (owner, 2026-10-19). Say what a thing does,
how to run it and what breaks; no filler, no marketing, no repetition.

- `README.md` is the short overview of the family's
  [README rule](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/repository-family.md#the-readme-rule)
  (owner, 2026-10-19), and `pyproject.toml` makes it the wheels' long description, so its links
  are absolute URLs. Installing a release, the Rust features and the Python bindings are in
  `getting_started.rst`; the suites, profiling, static analysis, tools and literature in
  `development_workflow.rst`; the Windows container build and the host run in
  `windows_workflow.rst`; features, dependencies and CI's compilers in `overview.rst`.
- Hand-written Sphinx sources live in `docs/source/`, with one exception: `graphviz_files.rst` is
  `graphviz_generator.py`'s output, tracked as a snapshot and rewritten by every `ci-docs.sh`
  run. What else `ci-docs.sh` writes (`docs/source/api/`, the `docs/source/test-results/*.md`
  pages, `docs/build/`) is untracked. Besides the sources, `docs/` tracks only the Sphinx
  `Makefile`/`make.bat` and `docs/packaging/WelcomeFile.txt`, the CPack welcome page. Doxygen via
  `Doxyfile.in`; coverage config in `gcovr.cfg`.
- `CHANGELOG.md`: a change here reaches OmniAccelerANT once its `third_party/AccelerANTgine` pin
  is bumped (and with it the in-tree `packages/kataglyphis_native_inference`), so note anything
  that moves the C ABI.
- Update docs in the same PR as user-facing behaviour changes.
