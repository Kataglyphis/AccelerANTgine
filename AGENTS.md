# AGENTS.md

Guidance for coding agents (and new contributors) working in
KataglyphisCppInference.

Laid out per ContainerHub's
[`shared/templates/AGENTS.md.template`](ExternalLib/Kataglyphis-ContainerHub/shared/templates/README.md).
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
| `scripts/windows/` | `Build-Windows.ps1`, `Build-PythonBindings.ps1`, the `start-*.ps1` entry points, and the `Resolve-BuildModule.ps1` bootstrap |
| `ExternalLib/Kataglyphis-ContainerHub` | The submodule owning every reusable script, module and doc |

**This repo is consumed as a nested submodule** by
`Kataglyphis_NativeInferencePlugin`, which is itself a submodule of
Kataglyphis-Inference-Engine. A change here has to reach two superprojects
before an app sees it.

## 2. What ContainerHub owns — links only

**Do not restate these procedures here.** Start at
[`ExternalLib/Kataglyphis-ContainerHub/docs/INDEX.md`](ExternalLib/Kataglyphis-ContainerHub/docs/INDEX.md),
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
| `scripts/linux/run-static-analysis-format.sh` | `linux/scripts/lib/code-quality.sh` |

CI jobs use ContainerHub's composite actions (`prepare-linux-ci-host`,
`run-in-linux-container`) rather than hand-written `docker run` blocks.

Two upstream facts repeated here only because they bite before you reach a doc:

- Every ContainerHub PowerShell module declares `#requires -Version 7.0`, so the
  Windows entry scripts do too — launch with `pwsh`, never `powershell`. Under
  5.1 it fails as an opaque `Import-Module` error.
- Composite actions resolve at `@main`, so a ContainerHub change a workflow
  depends on must be pushed **before** the consumer change.

**This repo's glue:** `scripts/windows/Resolve-BuildModule.ps1` — the one file
that cannot live upstream, because it is what *finds* the submodule.
`Build-Windows.ps1` imports `WindowsScripts.Shared`, `WindowsBuild.Common`,
`WindowsCMake.Common`, `WindowsMsix.Common`, `WindowsMsix.Signing` and
`WindowsOnnx.Common` from it. Nested imports inside a `.psm1` are
**module-private**, so every module you call into must be named in that list
explicitly.

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
  `knt_push_frame`, used by the Inference-Engine webcam path. Changing a
  signature here breaks a consumer two superprojects up, which no build in this
  repo will catch.
- **Sphinx config pulls its baseline from DocumANTation, via ContainerHub.**
  `docs/source/conf.py` loads `conf_base.py` from
  `ExternalLib/Kataglyphis-ContainerHub/external/Kataglyphis-DocumANTation/docs-tooling/source_templates/sphinx-book`.
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

`start-{build,debug,release,profile,python-bindings,help}.ps1` are the
convenience entry points over those.

CI lanes: `linux_run.yml` (containerized), `linux_run_x86.yml`,
`linux_run_arm.yml`, `windows_run.yml`.

## 5. Docs owned by this repo

- Sphinx sources in `docs/`; Doxygen via `Doxyfile.in`; coverage config in
  `gcovr.cfg`.
- `CHANGELOG.md` — and remember a change here surfaces in
  `Kataglyphis_NativeInferencePlugin` and then Kataglyphis-Inference-Engine, so
  note anything that moves the C ABI.
- Update docs in the same PR as user-facing behaviour changes.
