# AGENTS.md

Guidance for coding agents (and new contributors) working in
AccelerANTgine.

Laid out per ContainerHub's
[`shared/templates/AGENTS.md.template`](third_party/ContainerHub/shared/templates/README.md).
The rule that shapes it: *would this still be true in a different project?* If
yes, ContainerHub owns it and § 2 links to it. If no, it is written out in § 3.

## 1. What this project is

A C++23 inference library — ONNX Runtime for inference, GStreamer for media —
exposed three ways: a C API for native embedders, Python bindings, and a CLI.
It is built with CMake presets and uses **C++23 named modules** (`.ixx`), which
is the single fact that most shapes its tooling.

| Path | What lives there |
| --- | --- |
| `Src/` | The library: `onnx_inference_engine`, `gstreamer_pipeline`, `toml_config`, `config_loader`, `inference_lib`, plus `kataglyphis_c_api` (the embedder-facing ABI) and `rusty_code/` |
| `Bindings/`, `build-python/` | Python bindings and their build tree |
| `Test/` | Test sources |
| `scripts/linux/` | The `ci-*.sh` chain, driven end-to-end by `ci-run-all.sh` |
| `scripts/windows/` | `Build-Windows.ps1`, `Build-PythonBindings.ps1`, the `Start-*.ps1` entry points, and the `Resolve-BuildModule.ps1` bootstrap |
| `third_party/ContainerHub` | The submodule owning every reusable script, module and doc |

**This repo is consumed as a direct submodule** of OmniAccelerANT, at
`third_party/AccelerANTgine`. The Flutter plugin
`packages/kataglyphis_native_inference` lives in-tree there and links this repo
as a *sibling*: its `windows/CMakeLists.txt` and `linux/CMakeLists.txt` walk up
to the superproject root and `add_subdirectory()` the checkout at
`third_party/AccelerANTgine`. A change here has to reach one superproject
before an app sees it.

## 2. What ContainerHub owns — links only

**Do not restate these procedures here.** Start at
[`third_party/ContainerHub/docs/INDEX.md`](third_party/ContainerHub/docs/INDEX.md),
which maps topic → owning document, so these links survive upstream
reorganisation.

| Topic | Where |
| --- | --- |
| Wiring this repo to ContainerHub — resolver, actions, libraries | `docs/adopting-in-a-new-project.md` |
| Linux container builds | `docs/linux-build-basics.md` |
| Cross-compilation chain and its failure classes | `docs/linux-cross-builds.md`, `docs/cross-build-verification.md` |
| The Windows image, its entrypoint and known traps | `docs/windows-builds.md` |
| Bind mount vs tar-pipe, Dev Drive filter setup, container reuse | `docs/windows-container-build-performance.md` |
| clang-format / clang-tidy / cmake-format and the canonical configs | `docs/code-quality-tooling.md` |
| Job counts, per-job memory, why a build got OOM-killed | `docs/build-parallelism-memory-tuning.md` |
| The five shell-safety bug classes | ContainerHub `AGENTS.md` § *Shell safety conventions* |

**These scripts are wrappers, not implementations** — change behaviour upstream,
not here:

| Script | Upstream driver |
| --- | --- |
| `scripts/linux/ci-common.sh` | sources `linux/scripts/01-core/` (logging, retry, downloads, parallelism) |
| `scripts/linux/ci-coverage.sh` | `linux/scripts/lib/coverage.sh` — gcovr for GCC, llvm-cov for clang |
| `scripts/linux/run-static-analysis-format.sh` | `linux/scripts/lib/code-quality.sh` — the cmake-format gate fails loud (no tool, no green lane) and hands the library its uv venv bootstrap as shell functions over `01-core/python_uv.sh`, not helper scripts, for the same exec-bit filemode reason as `ci-docs.sh` |
| `scripts/linux/ci-build-and-test.sh` | `linux/scripts/lib/cmake-build.sh` + `linux/scripts/lib/ctest-run.sh` |
| `scripts/linux/ci-profile-bench.sh` | `linux/scripts/lib/cmake-build.sh` — the perf/benchmark run itself stays local |
| `scripts/linux/ci-docs.sh` | `linux/scripts/lib/docs-build.sh` + `linux/scripts/01-core/python_uv.sh` for the venv — calls the library steps individually, not `docs_build_main` (the script header says why: the venv bootstrap must run via `bash`, not rely on an exec bit filemode drops) |

CI jobs use ContainerHub's composite actions (`prepare-linux-ci-host`,
`run-in-linux-container`) rather than hand-written `docker run` blocks.

**CMake modules: ContainerHub-first, local override wins.** `CMakeLists.txt`
puts this repo's `cmake/` ahead of `third_party/ContainerHub/cmake/` on
`CMAKE_MODULE_PATH` and includes every module by name. All eleven reusable
modules now exist only upstream (CompilerWarnings, Doxygen, Hardening,
InterproceduralOptimization, PreventInSourceBuilds, Speedup,
StandardProjectSettings, and — reconciled upstream 2026-09-06 — Cache, Tests,
Sanitizers and StaticAnalyzers; Tests and Sanitizers carried this repo's
clang-cl coverage path and its ASan/UBSan runtime hand-work with them, and
StaticAnalyzers' clang-tidy gained an optional header-filter argument that
`ProjectOptions.cmake` fills with this repo's `Src/.*`). `cmake/` keeps only
this project's own policy — `ProjectOptions.cmake`, `CPackOptions.cmake`,
`SystemLibDependencies.cmake`, `fuzztest_compat/`. The old local
StaticAnalyzers copy's clang-tidy `--fix` and three check-disables stay
autofix-lane-only in `scripts/`; the report-only build gate now surfaces
those checks. The upstream Tests, Sanitizers and StaticAnalyzers merges only
reach this repo on the next ContainerHub submodule bump; until then
`include(Tests)` and `include(Sanitizers)` resolve to the pinned upstream
copies, which predate the clang-cl coverage path and the ASan/UBSan runtime
hand-work — so do not run a clang-cl Debug ASan build before that bump lands
(ContainerHub's `docs/windows-clang-cl-sanitizers.md` has the merged story) —
and `include(StaticAnalyzers)` resolves to the pinned copy, whose
two-parameter macro ignores the surplus header-filter argument, so clang-tidy
falls back to `.clang-tidy`'s `HeaderFilterRegex`.

Two upstream facts repeated here only because they bite before you reach a doc:

- Every ContainerHub PowerShell module declares `#requires -Version 7.0`, so the
  Windows entry scripts do too — launch with `pwsh`, never `powershell`. Under
  5.1 it fails as an opaque `Import-Module` error.
- Composite actions resolve at `@main`, so a ContainerHub change a workflow
  depends on must be pushed **before** the consumer change.

**This repo's glue:** `scripts/windows/Resolve-BuildModule.ps1` — the one file
that cannot live upstream, because it is what *finds* the submodule.
`Build-Windows.ps1` imports `WindowsScripts.Shared`, `WindowsBuild.Common`,
`WindowsUv.Common`, `WindowsFormatting.Common`, `WindowsCMake.Common`,
`WindowsMsix.Common`, `WindowsMsix.Signing` and `WindowsOnnx.Common` from it.
Nested imports inside a `.psm1` are **module-private**, so every module you
call into must be named in that list explicitly. Its Step 3 runs upstream
`Invoke-CmakeFormatStep` — uv venv plus `requirements.txt`, then in-place
cmake-format with `.cmake-format.yaml` — mirroring the Linux lane's gate; it
throws when uv or cmake-format is missing, and `-SkipFormat` opts out.

## 3. Pitfalls specific to this project

Everything here is false or meaningless in another repo — that is why it is
written out rather than linked.

- **clang-tidy is skipped for GCC on purpose.** A GCC-generated
  `compile_commands.json` carries C++ module flags clang-tidy cannot parse, so
  `run-static-analysis-format.sh` runs it only when `COMPILER=clang`. That is not
  an oversight and re-enabling it produces a wall of parse errors, not findings.
- **Three analyses stay local rather than going upstream:**
  `clang++ --analyze`, `scan-build-21`, and the `-DUSE_RUST=1` define they need.
  No other ContainerHub consumer runs them, and one consumer is not enough to
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
- **Sphinx config pulls its baseline from DocumANTation, via ContainerHub.**
  `docs/source/conf.py` loads `conf_base.py` from
  `third_party/ContainerHub/third_party/DocumANTation/docs-tooling/source_templates/sphinx-book`.
  It raises a clear error if that path is missing, which in practice means the
  nested submodule was not initialised recursively.
- **Presets are per-compiler and per-sanitizer**, not a single matrix:
  `linux-{debug,profile,RelWithDebInfo,release}-{clang,GNU}`,
  `linux-debug-clang-tsan`, and on Windows
  `x64-{MSVC,ClangCL}-Windows-{Debug,RelWithDebInfo,Profile,Release}`. Coverage
  requires a matching compiler — gcovr only reads GCC output, llvm-cov only clang.

## 4. Build, run, test

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

`Start-Build.ps1`, `Start-Debug.ps1`, `Start-Release.ps1`, `Start-Profile.ps1`,
`Start-PythonBindings.ps1` and `Start-Help.ps1` are the convenience entry
points over those. `Start-Build.ps1` and `Start-PythonBindings.ps1` run their
`Build-*.ps1` inside the ContainerHub Windows image via `Invoke-ContainerBuild`
(`WindowsContainerBuild.Reuse`, imported through `Resolve-BuildModule.ps1`):
tar-pipe transport into a reusable per-lane build container at `C:\ws` by
default, `-UseBindMount` to opt into a bind mount, `-FreshContainer` to reset,
`-WhatIf` to print the assembled in-container command without building. Build
output goes to the console and `logs/` — the old root-level `build*.log`
redirect files are gone, as is the image-baked `C:\workspace` mount target
(mounting over an image dir fails at CreateComputeSystem on host/image
OS-build skew).

CI lanes: `linux_run.yml` (containerized), `linux_run_x86.yml`,
`linux_run_arm.yml`, `windows_run.yml`.

## 5. Docs owned by this repo

- Sphinx sources in `docs/`; Doxygen via `Doxyfile.in`; coverage config in
  `gcovr.cfg`.
- `CHANGELOG.md` — and remember a change here surfaces in OmniAccelerANT once
  its `third_party/AccelerANTgine` pin is bumped (and thus in the in-tree
  `packages/kataglyphis_native_inference`), so note anything that moves the C
  ABI.
- Update docs in the same PR as user-facing behaviour changes.
