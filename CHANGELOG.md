# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**No release has been tagged yet.** `CMakeLists.txt` declares `VERSION 0.0.1`,
which is what CPack stamps into every artifact, but no `v0.0.1` tag exists on
the remote — so the link at the bottom points at the commit log rather than at a
`compare/` range that would 404. Cut a tag and this file gains a real section.

A change here surfaces in OmniAccelerANT only once its
`third_party/AccelerANTgine` pin is bumped (and thus in the in-tree
`packages/kataglyphis_native_inference`), so anything that moves the C ABI
belongs in the **Changed** list below with that consequence spelled out.

## [Unreleased]

### Added

- 2026-09-25 — `.github/workflows/windows-arm64-cross.yml` ("Windows arm64 · cross
  build + run", owner decision 2026-09-25), a thin caller of ANTfrastructure's
  reusable `container-ci-windows.yml`. `Build-Windows.ps1 -TargetArch arm64
  -BuildTargets clangcl-release` builds in the family image's arm64 bundle, the
  hub's arch gate grades `dist/windows-arm64`, and `windows-11-arm` runs
  `bundle/bin/AccelerANTgine.exe`. Verified locally in the bundle: 6/6 steps, 22
  arm64 binaries, no unresolved import, the `aarch64` MSI/ZIP and the arm64 MSIX.
  The first run caught the arm64 redist's ARM64EC `vcruntime140_1.dll` in the
  package; the hub's CPack module now leaves it out.
  Also fixed on the way: an error outside every build step was logged and the
  script still exited 0; it exits 1 now.
- 2026-09-14 — `.github/workflows/lint-gates.yml` plus
  `scripts/linux/run-lint-gates.sh`: shellcheck, actionlint, gitleaks and ruff
  over this tree. Before it the repo ran no lint gate of any kind while
  `linux_run.yml` deployed over FTP with three repository secrets.
- 2026-09-14 — `.github/workflows/submodule-pins.yml`, running ANTfrastructure's
  shared `Submodule.Pins.Tests.ps1` on every push that touches `.gitmodules` or
  `third_party/**`.
- 2026-09-15 — `.github/workflows/windows_run.yml` gained the PowerShell lint
  gate (`Invoke-Lint.ps1`, PSScriptAnalyzer 1.25.0) and a `pester-tests` job for
  `scripts/windows/tests/`.
- 2026-09-15 — `scripts/windows/Start-Windows.ps1`, one entry point replacing
  `Start-Debug.ps1`, `Start-Profile.ps1` and `Start-Release.ps1`, and
  `scripts/windows/Build-Windows.config.psd1`, the build-directory/preset table
  both of them read.
- 2026-09-15 — `scripts/windows/tests/Repo.GeneratedArtifacts.Tests.ps1`, which
  fails if a generated artifact is in the index — the guard `.gitignore` alone
  cannot be, because a rule does nothing once a path is already tracked.

### Changed

- 2026-09-24 — **workflows follow the owner's fleet naming convention**
  (kebab-case files, one file per platform + arch, display names
  `<Platform> <Arch> · <what>`). Renamed: `linux_run.yml` →
  `reusable-linux.yml` ("Linux · reusable build"), `linux_run_x86.yml` →
  `linux-x64.yml` ("Linux x64 · build + test"), `linux_run_arm.yml` →
  `linux-arm64.yml` ("Linux arm64 · build + test"), `windows_run.yml` →
  `windows-x64.yml` ("Windows x64 · build + test"); `lint-gates.yml` and
  `submodule-pins.yml` keep their files and now display as "Lint gates" and
  "Submodule pins". Triggers are unchanged — all three platform lanes still run
  on every push and PR to `main`/`develop`. The README badges, AGENTS.md, the
  Sphinx overview and every comment naming a workflow file moved with them;
  the entries below keep the names they had at the time. Touching the files
  also cleared all ten of this repo's hub workflow-convention findings: the two
  runner-owning `build` jobs carry `timeout-minutes` (120 Linux, 240 Windows,
  against measured green runs of at most 48 and 78 minutes), every renamed
  workflow declares `permissions:` (`contents: read` + `packages: read`, the
  repository's restricted default, so the token can do nothing it could not
  before), and both uploads set `if-no-files-found: error`.
- 2026-09-23 — **ONNX Runtime is REQUIRED and chain-only** (ANTfrastructure
  owner rule of 2026-09-23). `cmake/SystemLibDependencies.cmake` searches one
  prefix — `-DONNXRUNTIME_ROOT`, else `$ENV{ONNX_ROOT}` (Windows image) or
  `/usr/local/lib/onnxruntime-cpu` (Linux image) — with `NO_DEFAULT_PATH`, and
  configure stops with `FATAL_ERROR` when it is missing or when its runtime
  library does not embed the chain's ORT source root (`C:\temp\onnx-src\…`,
  `/opt/onnxruntime/…`). Gone: the `C:/onnxruntime`, `C:/onnx`, Program Files,
  vcpkg, `/opt/onnxruntime`, `/usr`, `/usr/local` and pkg-config fallbacks, the
  `ONNX_LIB`/`ONNX_INCLUDE` and `$ENV{ONNXRUNTIME_ROOT}` shortcuts, and the
  WARNING that told users to download a release or `apt install
  libonnxruntime-dev`. Also fixed: on Linux the search list used to be
  overwritten after the override was inserted, so `ONNXRUNTIME_ROOT` never
  applied there. A build without ORT (`HAS_ONNXRUNTIME=0`) is no longer
  reachable through a missing library. The CUDA EP code is unchanged.
  The shipped ORT is proved as well: `scripts/windows/Build-Windows.ps1` runs
  ANTfrastructure's G6 census (`Test-OrtProvenanceTree`) over each `bin\` after
  `Copy-MediaRuntimeBundle`, and `Build-PythonBindings.ps1` copies only the chain
  layout (`Get-OnnxChainLayout`; it used to copy every `onnxruntime*.dll` under
  `ONNX_ROOT`, NuGet trees included) and proves the package with G6 before it
  reports it staged. The CPack installers carry it as well: the NSIS, WiX and
  ZIP packages were built from `install()` rules that held no ORT, so an
  installed exe loaded System32's Windows ML copy. `SystemLibDependencies.cmake`
  now installs the proven `onnxruntime.dll` (+ `onnxruntime_providers_shared.dll`,
  `DirectML.dll`) into `bin\`, and the release step runs G6 over a
  `cmake --install` of the tree before `--target package`. Both scripts need the
  hub pin at its ORT single-source commit of 2026-09-23 or later and stop
  naming it otherwise: at the older pin the lane
  staged NuGet layouts only and the exe loaded System32's `onnxruntime.dll`.
- 2026-09-14 — `scripts/linux/run-static-analysis-format.sh` runs every analysis
  through ANTfrastructure's `01-core/gates.sh` and `require_tools`: no `|| true`
  and no warn-and-skip survive, so a missing tool is red rather than green.
- 2026-09-15 — `scripts/windows/Build-Windows.ps1` drives the hub's
  `Invoke-CmakeConfigureAndBuild`, `Invoke-CtestDiscoveredTests`,
  `Invoke-ClangTidyFixStep`, `Invoke-ClangFormatStep` and `Invoke-ToolchainChecks`
  instead of hand-rolled equivalents; its build-directory/preset table moved to
  `scripts/windows/Build-Windows.config.psd1`.
- 2026-09-15 — `scripts/linux/ci-release.sh` configures and builds through
  ANTfrastructure's `linux/scripts/lib/cmake-build.sh` and `lib/app-packaging.sh`;
  its hard-coded Flatpak runtime branch is gone in favour of the hub pin in
  `versions.env`. `ci-docs.sh` calls `docs_build_main` rather than
  re-implementing its step order.
- 2026-09-15 — `scripts/linux/ci-finalize.sh` no longer swallows a failed
  `chown`. It fixes only the paths whose ownership actually differs, is fatal
  when it fails as root, and explains itself when an unprivileged uid simply
  cannot hand a file to another owner.
- 2026-09-15 — `.gitignore` fences `*.onnx` and `*.bmp` with `models/yolo26n.onnx`
  and `images/Engine_logo.bmp` re-included: the two tracked binaries stay, no
  history is rewritten, and a third one cannot arrive unnoticed.
- 2026-09-15 — the three Windows wrappers that never launch the application were
  renamed to say so: `Start-Build.ps1` → `Invoke-ContainerBuild.ps1`,
  `Start-PythonBindings.ps1` → `Invoke-ContainerPythonBindings.ps1`,
  `Start-Help.ps1` → `Show-BuildHelp.ps1`.
- 2026-09-15 — `third_party/ANTfrastructure` moved to `49be50f0` and four
  helpers this repo had written locally, each under a header saying it would
  leave once the hub grew one, came from the hub instead.
  `scripts/linux/ci-release.sh` configures through a single `cmake_build_main`
  using the new repeatable `--configure-arg` — the hand-written
  `cmake -B … --preset` carrying `-DCMAKE_LINK_WHAT_YOU_USE` and
  `-DCPACK_ENABLE_APPIMAGE` is gone — and packages through
  `app_packaging_ensure_flatpak_runtime` and
  `app_packaging_package_cmake_install_flatpak`, which stage container-native
  (so a bind-mounted workspace cannot refuse the `fchmod` that
  `flatpak build-bundle` performs) and let `ostree` rather than
  flatpak-builder's exit code decide whether the app was committed.
  `scripts/linux/ci-finalize.sh` calls `01-core/bind-mount-ownership.sh`.
  `scripts/windows/Build-Windows.ps1` stages its media runtime through
  `WindowsMediaRuntime.Common`, whose recursive NuGet probe follows the target
  runtime identifier instead of a literal `win-x64`; this lane's presets are all
  `x64-*`, so it resolves to the same `win-x64` it always matched.
- 2026-09-15 — `third_party/ANTfrastructure` moved to `604294e2`, whose
  `app_packaging_require_flatpak_tools` requires `ostree` alongside `flatpak` and
  `flatpak-builder`, reports every missing tool rather than only the first, and
  names what the packaging step wanted each one for. That is the measurement this
  repo made earlier the same day — the packagers' verdict is an `ostree refs`
  query and Debian's `flatpak` depends on libostree rather than on the CLI, so a
  dev box without it reported "not committed" over an export that had succeeded
  — so the `has_tool ostree` branch `ensure_flatpak_tools` had grown is gone
  again. The function keeps its apt/`AUTO_INSTALL_FLATPAK` half, `ostree` among
  the packages it installs included: that knob serves a dev box the hub's
  container helper does not.

### Removed

- 2026-09-14 — generated output left the index: `docs/_build_validation/`,
  `docs/test-results*/`, `docs/test_results.xml` and `profile.prof`.
- 2026-09-15 — `Test/python/__pycache__/*.pyc` left the index; `__pycache__/` is
  now ignored.
- 2026-09-15 — 254 lines of local helper code, replaced by the hub rather than
  deleted: `ensure_flatpak_runtime` (32), `build_flatpak` (69) and
  `normalize_installed_file` (17) from `scripts/linux/ci-release.sh`;
  `fix_bind_mount_ownership` (45) from `scripts/linux/ci-finalize.sh`; and
  `Add-ExistingDirectory` (13), `Get-RuntimeDependencyDirectories` (45) and
  `Copy-RuntimeDependencies` (33) from `scripts/windows/Build-Windows.ps1`.
  `load_project_metadata` and `ensure_flatpak_tools` stayed: nothing upstream
  reads `CMakeCache.txt`, and the apt/`AUTO_INSTALL_FLATPAK` knob is for a dev
  box the hub's container helper does not serve.

### Fixed

- 2026-09-24 — **the docs step renders the test results itself, and for the first
  time.** Run 36052807549 passed build and tests, then died in `ci-docs.sh` at
  `Installing pandoc via apt` → `This script requires sudo or root`. The image has
  no pandoc and the lane runs as uid 1001. The pandoc block had always been there,
  but every earlier run failed in Sphinx before reaching it. Nothing had ever needed
  it either: `ctest --output-junit` writes `docs/test_results*.xml` (underscore),
  and the step globbed `test-results*.xml`/`test-*.xml`, so it converted nothing
  (`converted=0`). `scripts/linux/junit_to_markdown.py` (stdlib only) now turns
  each report into a Markdown page in `docs/source/test-results/`. That means one
  H1 page, a table per suite and the failed tests' output, with no raw HTML, so
  Sphinx `-W` reads it. It replaces junit2html (dropped from `requirements.txt`)
  and pandoc. The step reads exactly the files the test step writes, and it
  deletes stale generated pages before rendering. The site no longer copies
  `docs/test-results/`, which nothing writes now. `conf.py` listed
  `docs/source/test-results` in `html_extra_path`, and the HTML builder drops
  those directories from its sources, so the pages were never built at all (only
  linkcheck read them). They are real pages now. The index reaches them through a
  checked `:doc:` link instead of the `<test-results/>` URL, which only junit2html's
  copied output ever filled. Checked by running `ci-docs.sh` in the image on a copy
  of the tracked tree with this tree's two reports: html and linkcheck
  `build succeeded` under `-W`, and `test-results/test_results.html` has the six
  rows.
- 2026-09-24 — **every configuration's `bin\` carries the image's GStreamer core
  DLLs.** The first run with the import-closure report (36044940426) named the cause
  right away. The CLI was missing `gstreamer-1.0-0.dll`, `glib-2.0-0.dll`,
  `gobject-2.0-0.dll`, `gstapp-1.0-0.dll` and `gstanalytics-1.0-0.dll`, all
  imported by `AccelerANTgine.dll`. The VC++ runtime (14.51) and the ASan runtime
  already resolved from `bin\`. The hub's `Copy-MediaRuntimeBundle` looks for
  GStreamer only where its SDK installer puts it, and the image builds it into
  `C:\runtime\bin`, so it had staged only the 7 ONNX Runtime DLLs.
  `Copy-ImageGStreamerRuntime` copies that directory's DLLs (`GSTREAMER_BIN`
  overrides the path) with the same exclusion OmniAccelerANT's runner bundling
  uses: never an ORT-family DLL. It runs before each `Assert-BundleChainOrt`, so G6
  proves the final directory. The MSIX payload lists its files by name and does not
  change.
- 2026-09-24 — **the docs build renders the test-result pages before Sphinx reads
  them.** The Linux x64 lane (run 36035276548) failed `make linkcheck` on a single
  warning, made fatal by `-W`: `test-results/index.rst:9: toctree glob pattern '*'
  didn't match any documents`. `ci-docs.sh` copied `docs/test-results-md` into the
  Sphinx source before `docs_build_main`, but produced it after, so a fresh checkout
  built an empty toctree. A local rerun hid this by picking up the previous run's
  pages. The script now calls the library's four steps one by one and renders the
  pages between the venv (which installs junit2html) and Sphinx. A build with no
  JUnit XML at all gets a `no-results.md` page that says so, instead of an empty
  glob. Checked: shellcheck-warnings ratchet OK (7 frozen, none new), and the copy
  logic both ways (placeholder when empty; pages copied, stale placeholder removed).
- 2026-09-24 — **the host runs get the VC++ runtime of the toolset that built them, and
  say what is missing when a binary will not start.** With clang-tidy and the ASan helper
  fixed, run 36035275991 built everything and reached the host steps. The Debug suites
  passed there, but the CLI would not start ("Windows loader/runtime mismatch"). The suites
  are placeholders that never call the library, so the CLI is the first binary on the
  runner to load the real closure. The binaries come from the image's VS 2026 toolset
  (14.51), while the windows-2025 runner carries the VS 2022 redistributable, which is
  older and only backward-compatible. `Build-Windows.ps1` now copies the toolset's own CRT
  DLLs (`VCToolsRedistDir\x64\Microsoft.VC*.CRT`) beside every configuration's `bin\` and
  build root: Microsoft's supported app-local deployment, and build-tree only, since the
  installers pack the CMake install tree and MSIX names its files. When a binary still will
  not start, `Start-Windows.ps1` walks its import closure in the loader's order (exe dir,
  System32, PATH). It names every DLL it cannot find and the version each runtime DLL
  resolves to, so the next failure names its cause rather than the hub's single message
  for two exit codes. Both were checked on this host: the staging copies into both
  directories and warns without a redist; the report named `python314.dll` as missing for a
  lone `python.exe`.
- 2026-09-24 — **the Windows clang-tidy step skips every TU that reads a BMI**
  when no clang-tidy sits beside the compiler. With the MSVC runtime fixed (next
  entry), run 36008508666 built all 607 steps, then failed its first clang-tidy
  file: `config_loader.cpp: module file '…kataglyphis.config_loader.pcm' built
  from a different branch () than the compiler`. The image compiles with its
  patched LLVM, which ships no clang-tidy, so the step ran scoop's. The hub's
  default skip only matches `import kataglyphis`, which misses implementation
  units, `import nlohmann.json;` and `import tomlplusplus;`. The step now uses
  the compiler's own `clang-tidy.exe` when there is one (read from
  `CMAKE_CXX_COMPILER`), and otherwise skips the implementation units and every
  import, which leaves the six self-contained `.ixx` interfaces. This has been
  broken since the image switched compilers; weeks of earlier failures in the
  same lane hid it. AGENTS.md § 4 has the Windows half of "Every LLVM tool that
  reads clang's output must be the compiler's own".
- 2026-09-24 — one MSVC runtime for the whole build. abseil 20260526.0 sets
  `CMAKE_MSVC_RUNTIME_LIBRARY` to `MultiThreaded$<$<CONFIG:Debug>:Debug>DLL` in its
  own scope (its `CMakeLists.txt:64-67`), so under the clang-cl ASAN Debug preset,
  where `ProjectOptions` forces `MultiThreadedDLL`, every absl object carried MDd
  while the rest carried MD. The Windows lane compiled 550 of 607 steps and then
  died linking FUZZTEST's `grammar_domain_code_generator`: `lld-link:
  /failifmismatch: mismatch detected for 'RuntimeLibrary'` (MD_DynamicRelease vs
  `absl_flags_parse.lib` MDd_DynamicDebug). It stayed hidden behind the image's
  sccache endpoint, which failed every compile first. `cmake/MsvcRuntime.cmake`
  now pins every compiled third-party target to the project's runtime (end of
  `third_party/CMakeLists.txt`), and the root `CMakeLists.txt` fails the configure,
  naming the targets, if anything in this tree would still link another runtime.
  The check walks this project's tree only: embedded in a Flutter runner (the
  OmniAccelerANT plugin `add_subdirectory()`s it), the runner's targets are not
  judged. Proven on the real abseil 20260526.0 source: without the pin the check
  names `absl_base`, `absl_flags_parse`, … (MultiThreadedDebugDLL); with it, all
  93 compiled targets resolve to MultiThreadedDLL. Release builds, where
  `ProjectOptions` sets no runtime, are untouched.
- 2026-09-12 — the CI image reference is resolved from ANTfrastructure's
  `versions.env` instead of being retyped here.
- 2026-09-23 — **the clang lanes' coverage step measures again** (x64 and arm64,
  runs 35921977662 / 35921977310 stopped at `error: Test/compile/default.profraw:
  No such file or directory`). Three causes, each fixed here:
  `myproject_ENABLE_COVERAGE` has defaulted OFF since 927e8fc and
  `linux-debug-clang` never set it, so nothing was instrumented — the preset now
  sets it ON (`linux-debug-clang-tsan` does not inherit it and stays
  uninstrumented); `gtest_discover_tests` runs each test case as its own
  process, so one fixed `default.profraw` could hold at most the last one —
  `ci-build-and-test.sh` now sets `LLVM_PROFILE_FILE=<build>/profraw/%p.profraw`
  (emptied first) for the ctest and fuzz runs, and `ci-coverage.sh` merges every
  file there (new `--profraw-dir`, passed to both by `ci-run-all.sh`); and the
  image's PATH `llvm-profdata` is Ubuntu's LLVM 21, which refuses clang 23's raw
  profile format 11 — `ci-coverage.sh` now puts the compiler's own tools
  (`clang++ -print-prog-name=llvm-profdata`) first. The report's object is now
  `lib/libAccelerANTgine.so`, where `Src/` is compiled; `./compileTestSuite`'s
  own mapping held only `Test/`, which the ignore regex drops. Measured in the
  `latest-cross` image at `/workspace`: 10 profiles (6 test cases, 3 discovery
  runs, 1 fuzz run), the TSan tree with 0 instrumented build lines, and a report
  over the ten `Src/` files at 0.00% — the suites never call the library.
- 2026-09-23 — **`ci-profile-bench.sh` no longer dies with exit 127 where perf
  cannot run.** The gcc-x64 job of run 35921977662 got as far as `timeout:
  failed to execute process: No such file or directory` / `perf record failed
  with exit code 127`: the image has no `perf` (Ubuntu 26.04's
  `linux-tools-common` stopped shipping `/usr/bin/perf`; it is `linux-perf`
  now). A probe (`perf record` with the real options around `true`) now decides:
  where it fails, the lane WARNs with perf's own message and skips the recording
  (and, until the 2026-09-24 entry below, the workload with it); the benchmark
  suite runs either way. Where it passes, everything but the window-closing exit
  124 is still fatal, as since 072937a. README no longer claims the CI image
  carries perf and gperftools.
- 2026-09-24 — **a working `perf` records the whole window now; the 09-23 fix
  alone was not enough.** With `linux-perf` installed in a `--privileged`
  `latest-cross` container (how CI runs), the probe passed and the lane died
  `profiled workload exited cleanly before the 20s window closed`: the workload,
  `bin/AccelerANTgine --webrtc --source test`, is a WebRTC producer, and with no
  signalling server on its default `ws://127.0.0.1:8443` it logs `Connection
  refused`, breaks out on `StreamState::Error` (`Src/cli_main.cpp:250-258`) and
  returns 0 about 200 ms in. `ci-profile-bench.sh` now starts the image's
  `gst-webrtc-signalling-server` on `127.0.0.1:18443` (new `--signalling-port`)
  for the window, passes the CLI `--server=` to it, and stops it afterwards, on
  the failure paths too; a `--profile-args` that names its own `--server` gets
  no server. Where perf cannot run, the workload still runs for a
  `--smoke-seconds` window (10 s) without a recorder, so an early exit is red
  there as well — skipping it is what hid this in CI. Measured in the
  `latest-cross` image with `linux-perf` installed: the clang lane at CI's 180 s
  window recorded 1558 samples (12.6 MB `perf.data`), the gcc lane at 20 s 229,
  both closing on exit 124 with the benchmark suite after them; without perf
  the 10 s window closes the same way after `State: Connecting -> Streaming`,
  and no signalling server outlives a run.
- 2026-09-24 — **clang-tidy is the compiler's own, like the coverage tools.**
  Once coverage passed, the clang lane's next step failed in the image (CI never
  got that far): bare `clang-tidy` is Ubuntu's LLVM 21 and cannot read the
  module PCMs clang 23 writes (`module file … uses a newer format that cannot be
  read`, all 18 `Src/` files, `== clang-tidy: FAILED (exit 1) ==`). The
  `-print-prog-name` lookup moved from
  `ci-coverage.sh` into `ci-common.sh` (`compiler_llvm_tool`,
  `use_compiler_llvm_tools`); `ci-coverage.sh` uses it for `llvm-profdata` and
  `llvm-cov`, and `run-static-analysis-format.sh` for `clang-tidy` alone, in a
  subshell, so `clang-format` keeps the version its verdict was made with.
  Measured in the `latest-cross` image, the clang lane in `ci-run-all.sh` order:
  build + ctest, coverage (10 profiles merged) and all four static gates
  (cmake-format, clang-format, scan-build, clang-tidy from
  `/usr/local/llvm-target/bin`) exit 0. The ARM workflow stays red regardless:
  its gcc job dies compiling on `sanitizer/common_interface_defs.h`, because the
  image's native aarch64 GCC ships no libsanitizer — an image fix, AGENTS.md § 4.

## Historical measurements

Kept because they date a claim that is no longer true, which is the only reason
a measurement belongs in a changelog rather than in `AGENTS.md`.

- **2026-09-09, Renovate `--apply`.** At that date exactly one of the seven
  `.gitmodules` entries declared a `branch =` (`third_party/ANTfrastructure`,
  `branch = main`). `--apply --dry-run` found five behind (`FUZZTEST`,
  `GOOGLE_BENCHMARK`, `NLOHMANN_JSON`, `SPDLOG`, `nanobind`), printed all five
  as **REFUSED** because they named no branch, and ended in "nothing to apply"
  with `git status` unchanged. That refusal was the feature: an unset branch does
  not disarm `git submodule update --remote`, it makes it walk to the remote's
  *default* branch. Since 9a5653d all seven declare a branch, so `--apply` now
  moves every one that is behind.
- **2026-09-09, the report-only managers.** `pep621`, `pip_requirements`,
  `cargo` and `pre-commit` together returned two rows, both from
  `Src/rusty_code/Cargo.toml` and both printing `1.0 → 1.0`: the report shows the
  *manifest* value and the range already covered the new release (the JSON behind
  it said 1.0.194 → 1.0.200, updateType patch — a lock move). The same run warned
  `Rate limit exceeded for api.github.com`; the variable that clears that under
  `--platform=local` is `GITHUB_COM_TOKEN`, not `RENOVATE_TOKEN`.

<!-- Links -->
[Unreleased]: https://github.com/Kataglyphis/AccelerANTgine/commits/main
