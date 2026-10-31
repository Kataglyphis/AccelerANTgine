<div align="center">
  <a href="https://jonasheinle.de">
    <img src="https://raw.githubusercontent.com/Kataglyphis/AccelerANTgine/develop/images/logo.svg" alt="AccelerANTgine logo: latte art in the shape of an ant" width="200" />
  </a>

  <h1>AccelerANTgine</h1>

  <h4>The Kataglyphis family's C++23 inference core: ONNX Runtime on GStreamer media.</h4>
</div>

[![Linux arm64 · build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-arm64.yml/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-arm64.yml)
[![Linux x64 · build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-x64.yml/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-x64.yml)
[![Linux riscv64 · cross build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-riscv64.yml/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-riscv64.yml)
[![Windows x64 · build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-x64.yml/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-x64.yml)
[![Windows arm64 · cross build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-arm64-cross.yml/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-arm64-cross.yml)
[![CodeQL](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/github-code-scanning/codeql/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/github-code-scanning/codeql)
[![Automatic Dependency Submission](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/dependency-graph/auto-submission/badge.svg?branch=develop)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/dependency-graph/auto-submission)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)
[![Twitter](https://img.shields.io/twitter/follow/Cataglyphis_?style=social)](https://twitter.com/Cataglyphis_)

[**Docs site**](https://hardwareacceleratedai.jonasheinle.de/)

AccelerANTgine is a C++23 library running ONNX Runtime models on GStreamer media and streaming over WebRTC. It exposes a C API, Python bindings and a CLI.
[OmniAccelerANT](https://github.com/Kataglyphis/OmniAccelerANT)'s native plugin links it; CI builds and tests five lanes in the family's container images.

Windows packages carry the ONNX Runtime license and notices from the image wheel matching
the packaged DLL; see the [Windows workflow](docs/source/windows_workflow.rst).
Every package and wheel lists its third-party components with their license texts in `THIRD-PARTY-NOTICES.txt`
([licenses](https://hardwareacceleratedai.jonasheinle.de/third_party_licenses.html)).
Release builds log warnings and errors only; `--log_level` or `ACCELERANTGINE_LOG_LEVEL` raises the level.

Dependency updates: run `bash scripts/linux/renovate-local.sh` to report, `--apply --dry-run` to plan, and `--apply` to update. It checks direct submodules against their remote default branches and initializes missing checkouts on apply. CI checks the wrapper and config; see [the shared Renovate guide](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/dependency-updates.md).
The CMake formatter uses ANTfrastructure's locked uv tool project on both platforms.

Python dependencies are declared in `pyproject.toml` and locked in `uv.lock`; the documentation
environment uses `uv sync --locked --only-group docs --python 3.14` after recursive submodule checkout.

## Highlights

- **One library, three surfaces:** a C API for native embedders, Python bindings and a CLI.
- **ONNX Runtime on GStreamer media:** YOLO detection on pipeline frames, WebRTC out through `webrtcsink`.
- **C++23 named modules**, with Rust called from C++ through corrosion and cxx.
- **Five CI lanes:** Linux x64, arm64 and riscv64, Windows x64 and arm64.
- **Tested without a model file:** four C++ suites and the Python tests, the Debug ones under ASan, UBSan and TSan.
- **Releases that start outside the image:** `.deb`, tarball, AppImage, setup `.exe`, MSI, MSIX, zip and Python wheels.

## GPU package candidates

On demand: [Linux](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-gpu-candidate.yml) targets NVIDIA x64/arm64 and AMD x64;
[Windows](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-gpu-candidates.yml) targets NVIDIA/AMD x64. Open a successful run and download the matching artifact under **Artifacts**
(sign-in required). Candidates are unverified, separate from releases and need matching host GPU drivers and runtimes.
Both workflows also accept `workflow_call`; GPU hardware profiling remains opt-in.
The infrastructure pin and missing Windows image inputs currently block builds; see [getting started](https://github.com/Kataglyphis/AccelerANTgine/blob/develop/docs/source/getting_started.rst) for formats and verification.
CPU packages remain available through the existing lanes.

## Quick start

```bash
git clone --recurse-submodules --branch develop https://github.com/Kataglyphis/AccelerANTgine.git
cd AccelerANTgine
cmake --preset linux-debug-clang && cmake --build --preset linux-debug-clang
```

Run it in the family's Linux image (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`):
configure requires its chain ONNX Runtime. On Windows,
`pwsh -NoProfile -File .\scripts\windows\Invoke-ContainerBuild.ps1` builds in the Windows image.
Its [Windows workflow](https://hardwareacceleratedai.jonasheinle.de/windows_workflow.html)
describes the shared container source selection used by both Windows wrappers.
The Windows x64 lint job calls ANTfrastructure's shared PowerShell quality workflow, which installs
the pinned analyzer with retries when PowerShell Gallery is temporarily unavailable.
Windows build-wiring tests use the shared AST reader to reject syntax errors before checking steps.
The Windows CLI and demo executables embed the project icon through ANTfrastructure's shared CMake helper.
The MSIX also includes and verifies the project license; selected packaging fails when its SDK, manifest or logo is missing.
A release needs no build:
[Install From A Release](https://hardwareacceleratedai.jonasheinle.de/getting_started.html#install-from-a-release).

## Documentation

| Topic | Read |
| --- | --- |
| Prerequisites, installing a release, presets, the Rust crate, Python bindings | [Getting Started](https://hardwareacceleratedai.jonasheinle.de/getting_started.html) |
| Key features, project layout, dependencies, what CI builds with | [Overview](https://hardwareacceleratedai.jonasheinle.de/overview.html) |
| Frame formats, model contracts and inference errors | [Inference and preprocessing](https://hardwareacceleratedai.jonasheinle.de/inference_preprocessing.html) |
| Language models on ONNX Runtime GenAI: C++, C, Python and the CLI | [Text generation](https://hardwareacceleratedai.jonasheinle.de/text_generation.html) |
| The test suites, shared CI argument checks, profiling, static analysis and tools | [Development Workflow](https://hardwareacceleratedai.jonasheinle.de/development_workflow.html) |
| Windows container builds, shared runtime staging and host runs | [Windows Workflow](https://hardwareacceleratedai.jonasheinle.de/windows_workflow.html) |
| The C++ and C API | [API Reference](https://hardwareacceleratedai.jonasheinle.de/api_reference.html) |
| Include graphs | [Architecture](https://hardwareacceleratedai.jonasheinle.de/graphviz_files.html) |
| CI test results and coverage | [Test Results](https://hardwareacceleratedai.jonasheinle.de/test_results.html) |
| CI quality reports, Ruff/ty, PowerShell checks and refactor previews | [Shared quality tooling](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/code-quality-tooling.md) |
| The demo's model, fetched by checksum | [models/README.md](https://github.com/Kataglyphis/AccelerANTgine/blob/develop/models/README.md) |
| Rules for agents and contributors, dependency upgrades (Renovate) | [AGENTS.md](https://github.com/Kataglyphis/AccelerANTgine/blob/develop/AGENTS.md) |
| Known work | [BACKLOG.md](https://github.com/Kataglyphis/AccelerANTgine/blob/develop/BACKLOG.md) |
| Changes | [CHANGELOG.md](https://github.com/Kataglyphis/AccelerANTgine/blob/develop/CHANGELOG.md) |

## Contributing and contact

AccelerANTgine is one of the [Kataglyphis repositories](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/repository-family.md),
which share one way to contribute and one contact. Licence: MIT, see [LICENSE](https://github.com/Kataglyphis/AccelerANTgine/blob/develop/LICENSE).
