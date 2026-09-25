<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>AccelerANTgine</h1>

  <h4>This C++ inference project gives me a good starting point for hardware accelerated AI inference 🚀 </h4>
</div>
  
For the official docs follow this [link](https://hardwareacceleratedai.jonasheinle.de/).

[![Linux arm64 · build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-arm64.yml/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-arm64.yml)
[![Linux x64 · build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-x64.yml/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux-x64.yml)
[![Windows x64 · build + test](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-x64.yml/badge.svg?branch=main)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-x64.yml)
[![Windows arm64 · cross build + run](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-arm64-cross.yml/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows-arm64-cross.yml)
[![CodeQL](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/github-code-scanning/codeql)
[![Automatic Dependency Submission](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/dependency-graph/auto-submission/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/dependency-graph/auto-submission)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)
[![Twitter](https://img.shields.io/twitter/follow/Cataglyphis_?style=social)](https://twitter.com/Cataglyphis_)

## Table of Contents
- [About The Project](#about-the-project)
  - [Key Features](#key-features)
  - [Dependencies](#dependencies)
  - [Useful tools](#useful-tools)
- [Getting Started](#getting-started)
  - [Specific version requirements](#specific-version-requirements)
  - [Installation](#installation)
  - [Upgrades](#upgrades)
- [Tests](#tests)
- [Contributing](#contributing)
- [License](#license)
- [Contact](#contact)
- [Acknowledgements](#acknowledgements)
- [Literature](#literature)

## About The Project

This repo is dedicated to deliver AI inference on steroids.

Frequently tested under (what CI builds, in the family's container images):
* windows server 2025 x64 *__clang-cl (LLVM 23)__* with the VS 2026 toolset (MSVC 14.51);
  `cl.exe` builds (`msvc-debug`, the `x64-MSVC-*` presets) exist, but no lane runs them
* [clang-cl](https://learn.microsoft.com/de-de/cpp/build/clang-support-msbuild?view=msvc-170) to compile the rust crate on windows
* windows arm64: a *__clang-cl__* cross build of the release configuration, run on `windows-11-arm`
* ubuntu 26.04 x64 *__Clang 23__* and *__GCC 16.2__*
* ubuntu 26.04 ARM *__Clang 23__* and *__GCC 16.2__* (the GCC job waits on an image fix, `AGENTS.md` § 4)

### Key Features

<div align="center">

| Category            | Feature                      | Implement Status |
|---------------------|------------------------------|:----------------:|
| Build System        | CMake >= 3.31.6              |        ✔️        |
| Performance         | Performance Benchmark        |        ✔️        |
| Platform Support    | Linux/Windows support        |        ✔️        |
| Compiler Support    | Clang/GNU/MSVC support       |        ✔️        |
| Rust integration    | Call Rust code from C++      |        ✔️        |

</div>

**Legend:**
- ✔️ - completed  
- 🔶 - in progress  
- ❌ - not started



### Dependencies
This enumeration also includes submodules.
* [ANTfrastructure](https://github.com/Kataglyphis/ANTfrastructure) — the build
  hub: every reusable script, CMake module, PowerShell module and CI action this
  repo runs comes from `third_party/ANTfrastructure`, and its gitlink decides
  what the lanes actually execute
* [ONNX Runtime](https://onnxruntime.ai/) — inference
* [GStreamer](https://gstreamer.freedesktop.org/) — media pipelines
* [WebRTC](https://webrtc.org/) — realtime transport, through GStreamer's `webrtcsink`
* [abseil](https://github.com/abseil/abseil-cpp) — pinned to the version FUZZTEST declares (`AGENTS.md` § 3)
* [GSL](https://github.com/microsoft/GSL)
* [nlohmann_json](https://github.com/nlohmann/json)
* [tomlplusplus](https://github.com/marzer/tomlplusplus)
* [SPDLOG](https://github.com/gabime/spdlog)
* [nanobind](https://github.com/wjakob/nanobind) — the Python bindings
* [gtest](https://github.com/google/googletest)
* [gbenchmark](https://github.com/google/benchmark)
* [google fuzztest](https://github.com/google/fuzztest)

##### Optional
* [Rust](https://www.rust-lang.org/)
* [corrosion-rs](https://github.com/corrosion-rs/corrosion)
* [cxx](https://cxx.rs/)

### Useful tools
* [NSIS](https://nsis.sourceforge.io/Main_Page)
* [doxygen](https://www.doxygen.nl/index.html)
* [cppcheck](https://cppcheck.sourceforge.io/)
* [cmake](https://cmake.org/)
* [valgrind](https://valgrind.org/)
* [clangtidy](https://github.com/llvm/llvm-project)
* [visualstudio](https://visualstudio.microsoft.com/de/)
* [ClangPowerTools](https://www.clangpowertools.com/)
* [Codecov](https://app.codecov.io/gh)
* [Ccache](https://ccache.dev/)
* [Sccache](https://github.com/mozilla/sccache)

#### Benchmarking
* [gperftools](https://github.com/gperftools/gperftools)

### VSCode Extensions
* [CMake format](https://github.com/cheshirekow/cmake_format)
* [CMake tools](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cmake-tools)
* [CppTools](https://github.com/microsoft/vscode-cpptools)

<!-- GETTING STARTED -->
## Getting Started

### Specific version requirements

**C++23** or higher required.<br />
**C17** or higher required.<br />
**CMake 3.31.6** or higher required.<br />

### Installation

1. Clone the repo
   ```bash
   git clone --recurse-submodules https://github.com/Kataglyphis/AccelerANTgine.git
   ```
   > **_NOTE:_** In case you forgot the flag --recurse run the following command  
   ```bash
   git submodule update --init --recursive

   ```
   afterwards.
3. Optional: Using the newest clang compiler. Install via apt. See [here](https://apt.llvm.org/):
4. Optional: Run `third_party/ANTfrastructure/linux/scripts/02-toolchain/setup-dependencies.sh`
   for preparing important dev tools. The dependency installer is ANTfrastructure's;
   this repo does not carry a local copy.
5. Then build your solution with [CMAKE] (https://cmake.org/) <br />
  Here the recommended way over command line after cloning the repo:<br />
  > **_NOTE:_** Here we use CmakePresets to simplify things. Consider using it too
  or just build on a common way.
  
  For now the features in Rust are experimental, and they are ON by default:
  `RUST_FEATURES` defaults to ON and every preset but `x64-Clang-Windows-*` sets
  it, so a build needs Rust (cargo) installed, or `-DRUST_FEATURES=OFF`. In order
  to compile a rust crate on windows it has to be MSVC ABI compatible, so the
  crate's C++ is compiled with the compiler CMake was configured with:
  `Src/CMakeLists.txt` hands `CC`/`CXX` to cargo (`corrosion_set_env_vars`),
  which is clang-cl under the ClangCL presets.
  (`Src/rusty_code/.cargo/config.toml` is empty.)

  ONNX Runtime must be the family image's chain build: configure searches only
  `-DONNXRUNTIME_ROOT`, else the image's own prefix, and stops without it
  (`AGENTS.md` § 4).

  (for clarity: Assumption you are in the dir you have cloned the repo into; each
  preset names its own build directory, e.g. `build/` for `linux-debug-clang`)
  ```sh
  # enlisting all available presets
  $ cmake --list-presets=all
  $ cmake --preset <configurePreset-name>
  $ cmake --build --preset <buildPreset-name>
  ```

On Windows, through the same script CI runs:

```powershell
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1 -BuildTargets clangcl-debug -LogDir logs\debug
```

Build directories and presets are rows in
`scripts/windows/Build-Windows.config.psd1`, not parameters; each row also names
an environment variable that overrides it. `-LogDir` is relative to the
workspace. The script expects the family Windows image (its toolchain, its
GStreamer and its chain ONNX Runtime); from a host,
`.\scripts\windows\Invoke-ContainerBuild.ps1` runs it inside that image.

### Python bindings

The library is also exposed to Python through nanobind: the module lives in
`Bindings/python` (`kataglyphis_inference`), its tests in `Test/python`, and
`scripts/windows/Build-PythonBindings.ps1` (or `Invoke-ContainerPythonBindings.ps1`, which
runs it inside the ANTfrastructure Windows image) builds it on Windows and stages the
package, with its GStreamer and chain ONNX Runtime DLLs, into `build-python/python`.
It does not run `Test/python`: that is the `python_bindings` ctest, registered only by a
`KATAGLYPHIS_BUILD_PYTHON_BINDINGS=ON` configure with `BUILD_TESTING` on and pytest
importable, which no CI lane builds today.

### Upgrades

#### What is behind: Renovate as a local CLI

```bash
bash scripts/linux/renovate-local.sh                     # report (default: every manager this tree has)
bash scripts/linux/renovate-local.sh --managers pep621   # the pyproject pins
bash scripts/linux/renovate-local.sh --apply --dry-run   # the plan
bash scripts/linux/renovate-local.sh --apply             # gitlinks, manifests and their locks
```

Run it from WSL; it bootstraps a pinned, checksum-verified Node on first use.
`AGENTS.md` § 4 (Pitfalls) is the in-repo owner of this procedure — what `--apply` will and
will not move, the `FUZZTEST`/abseil coupling it can trip, the `GITHUB_COM_TOKEN`
rate-limit note — and
[`third_party/ANTfrastructure/docs/dependency-updates.md`](third_party/ANTfrastructure/docs/dependency-updates.md)
is the full rationale.

#### Rusty things:
1. Do not forget to upgrade the cxxbridge from time to time:
```bash
cargo install cxxbridge-cmd
```

# Tests
I have five tests suites.

1. Compilation Test Suite (`Test/compile`): built in every Debug configuration and run by ctest together with the commit suite. It is not run as part of the compilation itself.

2. Commit Test Suite (`Test/commit`): runs on every push and PR, wherever a lane builds Debug (the Linux lanes and Windows x64). More expensive tests are allowed :) 

3. Perf test suite (`Test/perf`, RelWithDebInfo builds): It is all about measurements of performance. We are C++ tho! 

4. Fuzz testing suite (`Test/fuzz`, Debug builds with Clang or clang-cl)

5. Python bindings test suite (`Test/python`), run against the built `kataglyphis_inference` module (see [Python bindings](#python-bindings): no CI lane runs it today).

## Performance tests

`ci-profile-bench.sh` is the profiling and benchmark lane, and it is what CI
runs:

```bash
bash scripts/linux/ci-profile-bench.sh
```

It links gperftools' `libprofiler` (`google-perftools`, `libgoogle-perftools-dev`)
when configure finds it, which writes `logs/profile.prof`; reading that profile
takes Go's `pprof` (plus `graphviz` for its graphs), which the lane itself never
calls. `valgrind --tool=callgrind` is reached through
`bash scripts/linux/ci-release.sh --callgrind`, and `perf record` needs a
`perf` binary (Ubuntu 26.04: the `linux-perf` package — `linux-tools-common` no
longer ships one) plus permission to open perf events. Installing them is not
this project's subject — the upstream install instructions for
[gperftools](https://github.com/gperftools/gperftools),
[pprof](https://github.com/google/pprof),
[valgrind](https://valgrind.org/docs/manual/cl-manual.html) and
[perf](https://perfwiki.github.io/main/) are the ones that stay correct. The CI
image does NOT carry the whole set: it has no `perf` (so the lane warns, runs
the workload for a short window without a recorder, then runs the benchmarks)
and no gperftools `libprofiler` (configure falls back to `-pg`).

A `perf` binary alone does not make a profile. The profiled workload is the
CLI's WebRTC producer on its synthetic source (`--webrtc --source test`), which
only streams while a signalling server answers; with none it gives up about
200 ms in. `ci-profile-bench.sh` therefore starts `gst-webrtc-signalling-server`
(gst-plugins-rs; the image has it) on `127.0.0.1:18443` for the window and
points the CLI there, unless `--profile-args` names a `--server` of its own.
`--signalling-port` moves it.

## Static analysis and formatting

One entry point per platform, and CI runs exactly these:

```bash
bash scripts/linux/run-static-analysis-format.sh
```

```powershell
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
```

They cover cmake-format and clang-format everywhere, plus clang-tidy and
`scan-build` on the Linux clang lane and clang-tidy in the Windows `clangcl-debug`
build, over the files the project actually compiles (`.ixx`, `.cppm` and `.mxx`
included). `clang++ --analyze` runs only when asked for (`--direct-analyze`).
Both formatters rewrite in place rather than failing on unformatted input. Every
one of them is a gate: a tool that is not installed fails the lane rather than
being skipped.

`.clang-format` and `.cmake-format.yaml` here are **shared** configs, and
`scripts/linux/run-lint-gates.sh` checks them against ANTfrastructure's copies
(the rows of `.antfrastructure-shared.manifest`) — edit them upstream, not here.
`.clang-tidy`, `gcovr.cfg` and `.pre-commit-config.yaml` are this project's own
on purpose; the manifest's header says why. What each tool does and
how to run one of them alone is in
[`third_party/ANTfrastructure/docs/code-quality-tooling.md`](third_party/ANTfrastructure/docs/code-quality-tooling.md),
and the configs themselves are described in
[`third_party/ANTfrastructure/shared/config/README.md`](third_party/ANTfrastructure/shared/config/README.md).

The pre-commit hook installs from the same `requirements.txt`:

```bash
uv venv
source .venv/bin/activate # .venv/Scripts/activate on pwsh
uv pip install -r requirements.txt
pre-commit install
pre-commit run --all-files   # once, optional
```

<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to be learn, inspire, and create. Any contributions you make are **greatly appreciated**.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request


<!-- LICENSE -->
## License

Distributed under the MIT License. See [`LICENSE`](LICENSE).

<!-- CONTACT -->
## Contact

Jonas Heinle - [@Cataglyphis_](https://twitter.com/Cataglyphis_) - jonasheinle@googlemail.com

[jonasheinle.de](https://jonasheinle.de/#/landingPage)
<!-- ACKNOWLEDGEMENTS -->
## Acknowledgements

## Literature 

Some very helpful literature, tutorials, etc. 

Rust
* [rust-lang](https://www.rust-lang.org/)

CMake/C++
* [ClangCL](https://clang.llvm.org/docs/MSVCCompatibility.html)
* [Cpp best practices](https://github.com/cpp-best-practices/cppbestpractices)
* [Integrate Rust into CMake projects](https://github.com/trondhe/rusty_cmake)
* [corrosion-rs](https://github.com/corrosion-rs/corrosion)
* [cxx](https://cxx.rs/)
* [C++ Software Design by Klaus Iglberger](https://meetingcpp.com/2024/Speaker/items/Klaus_Iglberger.html)
