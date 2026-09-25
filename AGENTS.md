# AGENTS.md

Guidance for coding agents (and new contributors) working in
AccelerANTgine.

Laid out per ANTfrastructure's
[`shared/templates/AGENTS.md.template`](third_party/ANTfrastructure/shared/templates/AGENTS.md.template).
The rule that shapes it: *would this still be true in a different project?* If
yes, ANTfrastructure owns it and § 2 links to it. If no, it is written out in § 4.

## 1. What this project is

A C++23 inference library — ONNX Runtime for inference, GStreamer for media —
exposed three ways: a C API for native embedders, Python bindings, and a CLI.
It is built with CMake presets and uses **C++23 named modules** (`.ixx`), which
is the single fact that most shapes its tooling.

| Path | What lives there |
| --- | --- |
| `Src/` | The library: `onnx_inference_engine`, `gstreamer_pipeline`, `toml_config`, `config_loader`, `inference_lib`, plus `kataglyphis_c_api` (the embedder-facing ABI) and `rusty_code/` |
| `Bindings/` | Python bindings (`Bindings/python`, tests in `Test/python`) |
| `Test/` | Test sources |
| `scripts/linux/` | The `ci-*.sh` chain, driven end-to-end by `ci-run-all.sh` |
| `scripts/windows/` | `Build-Windows.ps1` + its `Build-Windows.config.psd1` table, `Build-PythonBindings.ps1`, the entry points (`Start-Windows.ps1`, `Invoke-Container*.ps1`, `Show-BuildHelp.ps1`), the `Resolve-BuildModule.ps1` bootstrap, the project-local `modules/` (today `WindowsOrtBundle.Common`: the ONNX Runtime proof of a staged bundle), and the Pester suites in `tests/` |
| `third_party/ANTfrastructure` | The submodule owning every reusable script, module and doc |

**This repo is consumed as a direct submodule** of OmniAccelerANT, at
`third_party/AccelerANTgine`. The Flutter plugin
`packages/kataglyphis_native_inference` lives in-tree there and links this repo
as a *sibling*: its `windows/CMakeLists.txt` and `linux/CMakeLists.txt` walk up
to the superproject root and `add_subdirectory()` the checkout at
`third_party/AccelerANTgine`. A change here has to reach one superproject
before an app sees it.

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
| Bind mount vs tar-pipe, Dev Drive filter setup, container reuse | `docs/windows-container-build-performance.md` |
| clang-format / clang-tidy / cmake-format and the canonical configs | `docs/code-quality-tooling.md` |
| Job counts, per-job memory, why a build got OOM-killed | `docs/build-parallelism-memory-tuning.md` |
| The five shell-safety bug classes | `third_party/ANTfrastructure/AGENTS.md` § *Shell safety conventions* |

**These scripts are wrappers, not implementations** — change behaviour upstream,
not here:

| Script | Upstream driver |
| --- | --- |
| `scripts/linux/ci-common.sh` | sources `linux/scripts/01-core/` (logging, retry, downloads, parallelism) |
| `scripts/linux/ci-coverage.sh` | `linux/scripts/lib/coverage.sh` — gcovr for GCC, llvm-cov for clang |
| `scripts/linux/run-static-analysis-format.sh` | `linux/scripts/lib/code-quality.sh`, every analysis run through `01-core/gates.sh` (`run_gate` … `assert_gates`) with its tools `require_tools`'d rather than skipped — no tool, no green lane (the file header names the rule and its owner) |
| `scripts/linux/ci-build-and-test.sh` | `linux/scripts/lib/cmake-build.sh` + `linux/scripts/lib/ctest-run.sh` |
| `scripts/linux/ci-profile-bench.sh` | `linux/scripts/lib/cmake-build.sh` — the perf/benchmark run itself stays local |
| `scripts/linux/renovate-local.sh` | `linux/scripts/renovate-local.sh` — Renovate as a local CLI, plus the git half that applies what it can only detect (passes this repo's root) |
| `scripts/linux/ci-docs.sh` | `linux/scripts/lib/docs-build.sh` — `docs_build_main`, with the venv bootstrap handed over as two shell *functions* over `01-core/python_uv.sh`. Why functions and not helper scripts is one owner, the file header: git records a new `.sh` as 100644 under `core.filemode=false`, and a function name is a command with no file mode |
| `scripts/linux/ci-release.sh` | `linux/scripts/lib/cmake-build.sh` + `lib/app-packaging.sh` — job count, container env repair, flatpak arch mapping and the artifact assertion. The configure line is upstream too now: `cmake_build_main` with two repeatable `--configure-arg` flags, where a hand-written `cmake -B … --preset` used to sit. So is the whole flatpak bundle: `app_packaging_ensure_flatpak_runtime` + `app_packaging_package_cmake_install_flatpak`, which stage container-native and let `ostree` — not flatpak-builder's exit code — decide. `load_project_metadata` and `ensure_flatpak_tools` stay local, the latter for its apt/`AUTO_INSTALL_FLATPAK` knob alone: tool PRESENCE, `ostree` included, is `app_packaging_require_flatpak_tools` since 604294e2 |
| `scripts/linux/ci-finalize.sh` | `linux/scripts/01-core/bind-mount-ownership.sh` — `fix_bind_mount_ownership`, which this file carried locally and asked to have moved. Upstream kept the split that is the point of it: selective chown, never `-R`; tolerated and explained as non-root; fatal as root; a missing target is not an error |
| `scripts/linux/run-lint-gates.sh` | `linux/scripts/run-lint-gates.sh` — shellcheck, actionlint, gitleaks, ruff and the shared-config drift check, at pinned and SHA256-verified versions; passes this repo's root, which upstream refuses to infer. `--ratchets` adds the eight `--root` measurement gates plus doc-links, frozen in `comment-size.allow` and `shellcheck-warnings.allow` at the repo root; CI passes it |

CI jobs use ANTfrastructure's composite actions (`prepare-linux-ci-host`,
`run-in-linux-container`) rather than hand-written `docker run` blocks.

**CMake modules: ANTfrastructure-first, local override wins.** `CMakeLists.txt`
puts this repo's `cmake/` ahead of `third_party/ANTfrastructure/cmake/` on
`CMAKE_MODULE_PATH` and includes every module by name. Local `cmake/` holds
only this project's own policy — `ProjectOptions.cmake`, `CPackOptions.cmake`,
`SystemLibDependencies.cmake`, `fuzztest_compat/` — and everything else,
`Test/cmake/CommonTestBuild.cmake`'s GoogleTest registration (`GTestDiscovery`)
included, resolves by name from
[`third_party/ANTfrastructure/cmake`](third_party/ANTfrastructure/cmake/README.md).

Two upstream facts repeated here only because they bite before you reach a doc:

- Every ANTfrastructure PowerShell module declares `#requires -Version 7.0`, so the
  Windows entry scripts do too — launch with `pwsh`, never `powershell`. Under
  5.1 it fails as an opaque `Import-Module` error.
- Composite actions resolve at `@develop`, so a ANTfrastructure change a workflow
  depends on must be pushed **before** the consumer change.

**This repo's glue:** `scripts/windows/Resolve-BuildModule.ps1` — the one file
that cannot live upstream, because it is what *finds* the submodule. Everything
`Build-Windows.ps1` does with it — the module import list, the step shapes, why
a nested import inside a `.psm1` is module-private and every module therefore has
to be named explicitly — is the consumer calling convention in
[`third_party/ANTfrastructure/docs/adopting-in-a-new-project.md`](third_party/ANTfrastructure/docs/adopting-in-a-new-project.md)
§ 8, and the script's own comments are the second copy.

## 3. Critical invariant: submodule pins

Builds are only supported against the **recorded submodule gitlinks** — the
commits CI builds green. `git submodule update --checkout --recursive` restores
every pin. If a drifted submodule is what you actually want, update the gitlink
**and** fix the fallout in the same change.

- `third_party/FUZZTEST` and the abseil `FetchContent` pin in
  `third_party/CMakeLists.txt` MUST move together: the `GIT_TAG` there tracks
  the version FUZZTEST's `MODULE.bazel` declares, and a mismatch breaks e.g.
  `absl::random_mocking_access`. `cmake/fuzztest_compat/` papers over the
  header gap between the current pair — re-check it on every move.
- `third_party/ANTfrastructure`'s **own** nested submodule is a build input here,
  not just a transitive detail: `docs/source/conf.py` (:21-28) loads `conf_base.py`
  from
  `third_party/ANTfrastructure/third_party/DocumANTation/docs-tooling/source_templates/sphinx-book`
  and raises if it is absent, so the docs lane is pinned to whatever DocumANTation
  commit the ANTfrastructure gitlink carries. `git submodule update --init` without
  `--recursive` satisfies every other consumer here and breaks this one — which is
  why § 4 lists the symptom as a pitfall too. `docs/source/_static/css/custom.css`
  is a tracked SYMLINK into that same tree, and it fails more quietly: Sphinx
  renders without the brand stylesheet and says nothing. Its target named the
  pre-rename `third_party/ContainerHub` until 2026-09-15, which is also what the
  doc-links and code-size ratchets refuse to grade around — a tracked path that is
  not on disk fails them before they read a line of code.
- No other pin here has a recorded coupling (checked 2026-09-15).

Drift is guarded by ANTfrastructure's shared suite, run by
`.github/workflows/submodule-pins.yml` on every push and PR that touches
`.gitmodules` or `third_party/**`. It asserts that every configured submodule
is checked out, sits at its recorded commit, and is pinned to a commit a fresh
clone could restore — a pin that is on no remote branch works only on the
machine that made it. Its checkout needs `submodules: true`; without it the
suite FAILS rather than passing on an empty tree. Run it after any pin bump. It
does **not** check the coupling above; that is on you.

## 4. Pitfalls specific to this project

Everything here is false or meaningless in another repo — that is why it is
written out rather than linked.

- **clang-tidy is skipped for GCC on purpose.** A GCC-generated
  `compile_commands.json` carries C++ module flags clang-tidy cannot parse, so
  `run-static-analysis-format.sh` runs it only when `COMPILER=clang`. That is not
  an oversight and re-enabling it produces a wall of parse errors, not findings.
- **Three analyses stay local rather than going upstream:**
  `clang++ --analyze`, `scan-build-21`, and the `-DUSE_RUST=1` define they need.
  No other ANTfrastructure consumer runs them, and one consumer is not enough to
  justify moving code upstream — the two-consumer rule.
- **`.ixx` files are first-class sources.** Any tooling that globs C++ sources
  must include them; the shared `.pre-commit-config.yaml` regex upstream was
  extended for exactly this. A file-discovery change that drops `.ixx` silently
  shrinks the format and tidy sets rather than failing.
- **The C API is the ABI surface.** `Src/kataglyphis_c_api.{h,ixx,cpp}` and
  `kataglyphis_export.h` are what the native plugin links against — including
  `knt_push_frame`, used by the OmniAccelerANT webcam path. Changing a
  signature here breaks a consumer one superproject up, which no build in this
  repo will catch.
- **Sphinx config pulls its baseline from DocumANTation, via ANTfrastructure.**
  `docs/source/conf.py` loads `conf_base.py` from
  `third_party/ANTfrastructure/third_party/DocumANTation/docs-tooling/source_templates/sphinx-book`.
  It raises a clear error if that path is missing, which in practice means the
  nested submodule was not initialised recursively.
- **Two binaries are tracked on purpose, and one of them is big.**
  `models/yolo26n.onnx` is 9.5 MiB — the YOLO weights `Test/` and the inference
  demo load, with no download step anywhere in the build, so a fresh clone that
  did not carry it would fail at runtime rather than at configure time.
  `images/Engine_logo.bmp` (156 KiB) is the NSIS installer header image
  (`cmake/CPackOptions.cmake`), which CPack reads as a literal path at package
  time. Both predate this note and **stay** — the history is not rewritten and
  no LFS is introduced. `.gitignore` carries `*.onnx` / `*.bmp` with exactly
  these two re-included, so a *second* model or bitmap dropped beside them is
  not committed unnoticed; that is the guard, not a size limit.
- **Dependency upgrades are Renovate as a local CLI, and nothing else.** The
  Renovate GitHub App is installed on no repo in this family and will not be, and
  there is no `.github/dependabot.yml` here, so this wrapper is the only
  dependency watch this repo has. It gates nothing: no workflow runs it, it
  blocks no commit, and it stages and commits nothing.

  ```bash
  bash scripts/linux/renovate-local.sh                     # report (default: git-submodules)
  bash scripts/linux/renovate-local.sh --managers pep621   # the pyproject pins
  bash scripts/linux/renovate-local.sh --apply --dry-run   # the plan
  bash scripts/linux/renovate-local.sh --apply             # move the gitlinks
  ```

  Run it from **WSL**: it bootstraps a pinned, checksum-verified Node, and there
  is none on the Windows host. All seven `.gitmodules` entries declare a
  `branch =` since 9a5653d, so none of them comes back **REFUSED** any more and
  `--apply` moves the gitlink of every one that is behind — `FUZZTEST` included,
  which must move together with the abseil pin (§ 3). The Python, Rust and
  pre-commit managers stay report-only. Under `--platform=local` the variable
  that clears `Rate limit exceeded for api.github.com` is `GITHUB_COM_TOKEN`, not
  `RENOVATE_TOKEN`. Full rationale:
  [`third_party/ANTfrastructure/docs/dependency-updates.md`](third_party/ANTfrastructure/docs/dependency-updates.md);
  the measurement that dated the old "exactly one declares a branch" claim is in
  `CHANGELOG.md`.
- **ONNX Runtime is REQUIRED and must be the family's chain build.**
  `cmake/SystemLibDependencies.cmake` searches exactly one prefix
  (`-DONNXRUNTIME_ROOT`, else the image's `ONNX_ROOT` on Windows or
  `/usr/local/lib/onnxruntime-cpu` on Linux) and refuses a runtime library that
  does not embed the chain's ORT source root — so a host without the image's ORT
  fails at configure time, by design (owner rule 2026-09-23). Do not add a
  fallback path, a pkg-config probe or a "download it" hint back; point
  `ONNXRUNTIME_ROOT` at a chain-built prefix instead. What ships is proved too:
  every `bin\` the Windows lane stages (hub `Copy-MediaRuntimeBundle`), the
  release install tree the NSIS/WiX/ZIP installers pack (the same CMake file
  installs the proven `onnxruntime.dll` and its companions into `bin\`, and the
  lane proves a `cmake --install` of it before `--target package`), the MSIX
  payload, and the Python package (`Build-PythonBindings.ps1`, the chain layout
  only) go through
  ANTfrastructure's G6 census (`Test-OrtProvenanceTree`, via
  `scripts/windows/modules/WindowsOrtBundle.Common.psm1`): every ORT binary the
  image's chain build, byte for byte, and `onnxruntime.dll` beside the exe (or
  in the package's `_libs`). Both scripts stop, naming the hub commit, while the
  pinned hub predates G6: that older hub staged NuGet layouts only, so the exe
  loaded System32's Windows ML `onnxruntime.dll`.
- **Presets are per-compiler and per-sanitizer**, not a single matrix:
  `linux-{debug,profile,RelWithDebInfo,release}-{clang,GNU}`,
  `linux-debug-clang-tsan`, and on Windows
  `x64-{MSVC,ClangCL}-Windows-{Debug,RelWithDebInfo,Profile,Release}`. Coverage
  requires a matching compiler — gcovr only reads GCC output, llvm-cov only clang.
- **llvm-cov coverage is `linux-debug-clang`'s, one profile per process.**
  `myproject_ENABLE_COVERAGE` defaults OFF (since 927e8fc), so the preset sets it
  ON; `linux-debug-clang-tsan` inherits `linux-clang`, not that preset, and stays
  uninstrumented. `gtest_discover_tests` runs every test case as its own process,
  so `ci-build-and-test.sh` points `LLVM_PROFILE_FILE` at
  `<build>/profraw/%p.profraw` (emptied first) for the ctest and fuzz runs, and
  `ci-coverage.sh` merges every file there into one indexed profile before the
  hub's `coverage_llvm_report`, which takes ONE profile path and ONE object. The
  object is `lib/libAccelerANTgine.so`, where `Src/` lives — a test executable's
  own mapping holds only `Test/`, which the ignore regex drops. The report
  reading 0.00% for every `Src/` file is the truth, not a broken merge: the
  `Test/` suites are placeholders that never call the library.
  `linux-debug-GNU` does not set the option, so the GCC lane's gcovr step
  reports `0 out of 0` lines.
- **Every LLVM tool that reads clang's output must be the compiler's own.** The
  image's `clang`/`clang++` are a source-built LLVM 23 (`/usr/local/llvm-target`),
  but bare `clang-tidy`, `llvm-profdata` and `llvm-cov` on PATH are Ubuntu's
  LLVM 21: `llvm-profdata` refuses clang 23's raw profile format 11 (`no profile
  can be merged`), and `clang-tidy` fails all 18 `Src/` files on the module
  PCMs the build wrote (`module file … uses a newer format that cannot be
  read`). `ci-common.sh`'s `use_compiler_llvm_tools` asks the configured
  compiler (`-print-prog-name`) and puts its directory first on PATH:
  `ci-coverage.sh` for the profile pair, `run-static-analysis-format.sh` for
  `clang-tidy` only, in a subshell, so `clang-format`'s version — a format
  verdict of its own — does not move with it. The image-side fix is upstream:
  the hub's `register-llvm-alternatives.sh` registers only `clang`, `clang++`,
  `llvm-ar` and `llvm-ranlib`.
  Windows has the same trap with a different pair: the image compiles with its
  patched LLVM (`C:/llvm-patched/bin/clang-cl.exe`, built `clang;lld` only), so
  the `clang-tidy` on PATH is scoop's, and it refuses the BMIs with `module file
  … built from a different branch () than the compiler`. `Build-Windows.ps1`'s
  clang-tidy step reads `CMAKE_CXX_COMPILER` from the build's `CMakeCache.txt`
  and uses a `clang-tidy.exe` beside it when there is one. There is none today,
  so it skips every TU that reads a BMI: the implementation units
  (`module kataglyphis.x;`) and anything that imports, `export import`
  included. That leaves the six `.ixx` interfaces that import nothing, where
  Linux analyses all 18 files. The image-side fix is adding
  `clang-tools-extra` to the hub's `Build-LlvmFromSource.ps1`, which re-keys the
  LLVM layer and everything built on it.
- **perf is optional in `ci-profile-bench.sh`, the CI image has none, and perf
  alone is not a profile.** Ubuntu 26.04's `linux-tools-common`, which the image
  installs, no longer ships `/usr/bin/perf` — perf is the `linux-perf` package
  now — so a bare `timeout … perf record` died with exit 127. The script probes
  `perf record` (same options) around `true`; where that fails it WARNs with
  perf's own message, records nothing, and still runs the workload for a
  `--smoke-seconds` window (10 s) without a recorder, so a workload that stops
  streaming early fails the lane either way; then the benchmark suite. The
  workload, `bin/AccelerANTgine --webrtc --source test`, is a WebRTC producer:
  with no signalling server on its URI it gets `Connection refused`, its loop
  breaks on `StreamState::Error` and it returns 0 about 200 ms in — measured with
  `linux-perf` installed in a `--privileged` image container, which is how CI
  runs. So unless `--profile-args` names its own `--server`, the script starts
  the image's `gst-webrtc-signalling-server` on `127.0.0.1:18443`
  (`--signalling-port`; not the CLI's default 8443, which a dev box's own
  producer holds) for the window and points the CLI at it. Where the probe
  passes, everything but the window-closing exit 124 stays fatal. A CI perf
  profile still needs `linux-perf` in the image, an ANTfrastructure change, and
  with no consumer attached the producer mostly idles: 150 to 230 samples in a
  20 s window were measured, not a hot loop.
- **`linux-arm64.yml`'s gcc job is red at build time, and not because of this
  repo.** `linux-debug-GNU` is a Debug build, which turns ASan on
  (`cmake/ProjectOptions.cmake`); abseil then includes
  `sanitizer/common_interface_defs.h`, and the image's native aarch64 GCC
  (`/opt/gcc-16.2.0`) ships no libsanitizer, so the build dies on that header
  (every ARM run since 32168022135 that got as far as compiling, 35921977310
  included). The fix is the image's —
  ANTfrastructure's GCC build has to build libsanitizer for a native GCC — so a
  green `linux-arm64.yml` waits for that image whatever the clang lanes do.

## 5. Build, run, test

The whole Linux CI chain, in order:

```bash
bash scripts/linux/ci-run-all.sh
```

which runs `ci-init.sh` → `ci-build-and-test.sh` → `ci-coverage.sh` →
`run-static-analysis-format.sh` → `ci-profile-bench.sh` → `ci-docs.sh` →
`ci-release.sh` → `ci-finalize.sh`. Each is runnable on its own with the same
arguments `ci-run-all.sh` passes it.

Windows:

```powershell
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
pwsh -NoProfile -File .\scripts\windows\Build-PythonBindings.ps1
```

`Start-Windows.ps1 -Config Debug|Profile|Release` runs what a build produced on
the host: CLI check, then that configuration's suites. It is one script because
the three it replaced differed only in a build directory and a suite list, and
it reads that build directory from `Build-Windows.config.psd1` — the same table
`Build-Windows.ps1` builds into, so producer and consumer cannot disagree.

`Invoke-ContainerBuild.ps1`, `Invoke-ContainerPythonBindings.ps1` and
`Show-BuildHelp.ps1` are the other entry points — named for what they do, because
none of them starts the application. The first two run their
`Build-*.ps1` inside the ANTfrastructure Windows image via `Invoke-ContainerBuild`
(`WindowsContainerBuild.Reuse`, imported through `Resolve-BuildModule.ps1`):
tar-pipe transport into a reusable per-lane build container at `C:\ws` by
default, `-UseBindMount` to opt into a bind mount, `-FreshContainer` to reset,
`-WhatIf` to print the assembled in-container command without building. Build
output goes to the console and `logs/` — the old root-level `build*.log`
redirect files are gone, as is the image-baked `C:\workspace` mount target
(mounting over an image dir fails at CreateComputeSystem on host/image
OS-build skew).

CI lanes, named by the owner's fleet convention of 2026-09-24 — kebab-case
files, one file per platform + arch, display names `<Platform> <Arch> · <what>`:
`linux-x64.yml` and `linux-arm64.yml` (each calls the containerized
`reusable-linux.yml` once per compiler), `windows-x64.yml` (the container build,
the PowerShell lint gate over `scripts/`, and a `pester-tests` job over
`scripts/windows/tests/`), `lint-gates.yml` and `submodule-pins.yml`. The three
platform lanes run on every push and PR to `main` and `develop`, with no path
filter. Every job that owns a runner carries `timeout-minutes`, every workflow
declares `permissions:`, and every upload sets `if-no-files-found: error` — the
hub's workflow conventions (`verify_workflow_conventions.py`), measured at zero
findings here since the rename.

`lint-gates.yml` and `submodule-pins.yml` are one `uses:` line each onto
ANTfrastructure's reusable workflows; only this repo's `on:` filters and their
inputs (`submodules: 'recursive'` and `ratchets: true` for the lint gates,
`pester-version: '3.4.0'` for the pins) stay local. `lint-gates.yml` runs the
same aggregator a dev box runs — `bash scripts/linux/run-lint-gates.sh
--ratchets` — against the same explicit root; it reaches it from the hub
checkout rather than through the wrapper, because the wrappers sit at different
paths across the family.

## 6. Docs owned by this repo

- Hand-written Sphinx sources live in `docs/source/`; everything else under
  `docs/` is regenerated by `ci-docs.sh` and untracked. Doxygen via
  `Doxyfile.in`; coverage config in `gcovr.cfg`.
- `CHANGELOG.md` — and remember a change here surfaces in OmniAccelerANT once
  its `third_party/AccelerANTgine` pin is bumped (and thus in the in-tree
  `packages/kataglyphis_native_inference`), so note anything that moves the C
  ABI.
- Update docs in the same PR as user-facing behaviour changes.
