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

- 2026-09-12 — the CI image reference is resolved from ANTfrastructure's
  `versions.env` instead of being retyped here.

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
