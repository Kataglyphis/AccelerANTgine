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
| `scripts/windows/` | `Build-Windows.ps1`, `Build-PythonBindings.ps1`, the `Start-*.ps1` entry points, and the `Resolve-BuildModule.ps1` bootstrap |
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
| The five shell-safety bug classes | ANTfrastructure `AGENTS.md` § *Shell safety conventions* |

**These scripts are wrappers, not implementations** — change behaviour upstream,
not here:

| Script | Upstream driver |
| --- | --- |
| `scripts/linux/ci-common.sh` | sources `linux/scripts/01-core/` (logging, retry, downloads, parallelism) |
| `scripts/linux/ci-coverage.sh` | `linux/scripts/lib/coverage.sh` — gcovr for GCC, llvm-cov for clang |
| `scripts/linux/run-static-analysis-format.sh` | `linux/scripts/lib/code-quality.sh`, every analysis run through `01-core/gates.sh` (`run_gate` … `assert_gates`) with its tools `require_tools`'d rather than skipped — no tool, no green lane; the uv venv bootstrap is handed over as shell functions over `01-core/python_uv.sh`, not helper scripts, for the same exec-bit filemode reason as `ci-docs.sh` |
| `scripts/linux/ci-build-and-test.sh` | `linux/scripts/lib/cmake-build.sh` + `linux/scripts/lib/ctest-run.sh` |
| `scripts/linux/ci-profile-bench.sh` | `linux/scripts/lib/cmake-build.sh` — the perf/benchmark run itself stays local |
| `scripts/linux/renovate-local.sh` | `linux/scripts/renovate-local.sh` — Renovate as a local CLI, plus the git half that applies what it can only detect (passes this repo's root) |
| `scripts/linux/ci-docs.sh` | `linux/scripts/lib/docs-build.sh` + `linux/scripts/01-core/python_uv.sh` for the venv — calls the library steps individually, not `docs_build_main` (the script header says why: the venv bootstrap must run via `bash`, not rely on an exec bit filemode drops) |

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
- Composite actions resolve at `@main`, so a ANTfrastructure change a workflow
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
- No other pin here has a recorded coupling (checked 2026-09-14).

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
- **Presets are per-compiler and per-sanitizer**, not a single matrix:
  `linux-{debug,profile,RelWithDebInfo,release}-{clang,GNU}`,
  `linux-debug-clang-tsan`, and on Windows
  `x64-{MSVC,ClangCL}-Windows-{Debug,RelWithDebInfo,Profile,Release}`. Coverage
  requires a matching compiler — gcovr only reads GCC output, llvm-cov only clang.

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

`Start-Build.ps1`, `Start-PythonBindings.ps1` and `Start-Help.ps1` are the other
entry points. `Start-Build.ps1` and `Start-PythonBindings.ps1` run their
`Build-*.ps1` inside the ANTfrastructure Windows image via `Invoke-ContainerBuild`
(`WindowsContainerBuild.Reuse`, imported through `Resolve-BuildModule.ps1`):
tar-pipe transport into a reusable per-lane build container at `C:\ws` by
default, `-UseBindMount` to opt into a bind mount, `-FreshContainer` to reset,
`-WhatIf` to print the assembled in-container command without building. Build
output goes to the console and `logs/` — the old root-level `build*.log`
redirect files are gone, as is the image-baked `C:\workspace` mount target
(mounting over an image dir fails at CreateComputeSystem on host/image
OS-build skew).

CI lanes: `linux_run.yml` (containerized, called by `linux_run_x86.yml` and
`linux_run_arm.yml`), `windows_run.yml`, `lint-gates.yml`,
`submodule-pins.yml`.

## 6. Dependency upgrades

Renovate, run as a **local CLI** — never by hand, and never by a bot. The
Renovate GitHub App is installed on no repo in this family and will not be, and
this repo has no `.github/dependabot.yml` either, so this wrapper is the **only**
dependency watch it has. It is not a gate: no workflow runs it, it blocks no
commit, and it stages and commits nothing.

```bash
bash scripts/linux/renovate-local.sh                     # report (default: git-submodules)
bash scripts/linux/renovate-local.sh --managers pep621   # the pyproject pins
bash scripts/linux/renovate-local.sh --apply --dry-run   # the plan
bash scripts/linux/renovate-local.sh --apply             # move the gitlinks
```

Run it from **WSL** — it bootstraps a pinned, checksum-verified Node, and there
is none on the Windows host.

All seven submodules declare a `branch =` since 9a5653d, so `--apply` moves
gitlinks (and nothing else) for any that are behind — `FUZZTEST` included,
which must move together with the abseil pin in `third_party/CMakeLists.txt`
(§ 3); the Python, Rust and pre-commit sides stay report-only.

Full rationale:
[`third_party/ANTfrastructure/docs/dependency-updates.md`](third_party/ANTfrastructure/docs/dependency-updates.md).

## 7. Docs owned by this repo

- Hand-written Sphinx sources live in `docs/source/`; everything else under
  `docs/` is regenerated by `ci-docs.sh` and untracked. Doxygen via
  `Doxyfile.in`; coverage config in `gcovr.cfg`.
- `CHANGELOG.md` — and remember a change here surfaces in OmniAccelerANT once
  its `third_party/AccelerANTgine` pin is bumped (and thus in the in-tree
  `packages/kataglyphis_native_inference`), so note anything that moves the C
  ABI.
- Update docs in the same PR as user-facing behaviour changes.
