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

AccelerANTgine is a C++23 library
that runs ONNX Runtime models on GStreamer media and streams over WebRTC, exposed three ways: a C
API for native embedders, Python bindings and a CLI. It is the inference core that
[OmniAccelerANT](https://github.com/Kataglyphis/OmniAccelerANT)'s native plugin links, and CI
builds and tests it on five lanes in the family's container images.

Dependency updates: run `bash scripts/linux/renovate-local.sh` to report, `--apply --dry-run` to plan,
and `--apply` to update. CI checks the wrapper and config; see
[the shared Renovate guide](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/dependency-updates.md).

## Highlights

- **One library, three surfaces:** a C API for native embedders, Python bindings and a CLI.
- **ONNX Runtime on GStreamer media:** YOLO detection on pipeline frames, WebRTC out through `webrtcsink`.
- **C++23 named modules**, with Rust called from C++ through corrosion and cxx.
- **Five CI lanes:** Linux x64, arm64 and riscv64, Windows x64 and arm64.
- **Tested without a model file:** four C++ suites and the Python tests, the Debug ones under ASan, UBSan and TSan.
- **Releases that start outside the image:** `.deb`, tarball, AppImage, setup `.exe`, MSI, MSIX, zip and Python wheels.

## Quick start

```bash
git clone --recurse-submodules --branch develop https://github.com/Kataglyphis/AccelerANTgine.git
cd AccelerANTgine
cmake --preset linux-debug-clang && cmake --build --preset linux-debug-clang
```

Run it in the family's Linux image (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`):
configure requires its chain ONNX Runtime. On Windows,
`pwsh -NoProfile -File .\scripts\windows\Invoke-ContainerBuild.ps1` builds in the Windows image.
A release needs no build:
[Install From A Release](https://hardwareacceleratedai.jonasheinle.de/getting_started.html#install-from-a-release).

## Documentation

| Topic | Read |
| --- | --- |
| Prerequisites, installing a release, presets, the Rust crate, Python bindings | [Getting Started](https://hardwareacceleratedai.jonasheinle.de/getting_started.html) |
| Key features, project layout, dependencies, what CI builds with | [Overview](https://hardwareacceleratedai.jonasheinle.de/overview.html) |
| Frame formats, model contracts and inference errors | [Inference and preprocessing](https://hardwareacceleratedai.jonasheinle.de/inference_preprocessing.html) |
| The test suites and lanes, profiling, static analysis, useful tools, literature | [Development Workflow](https://hardwareacceleratedai.jonasheinle.de/development_workflow.html) |
| The Windows container build and the host run | [Windows Workflow](https://hardwareacceleratedai.jonasheinle.de/windows_workflow.html) |
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
