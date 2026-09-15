<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>AccelerANTgine</h1>

  <h4>This C++ inference project gives me a good starting point for hardware accelerated AI inference 🚀 </h4>
</div>
  
For the official docs follow this [link](https://hardwareacceleratedai.jonasheinle.de/).

[![Linux run on ARM/GCC/Clang](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux_run_arm.yml/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux_run_arm.yml)
[![Linux run on x86/GCC/Clang](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux_run_x86.yml/badge.svg)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/linux_run_x86.yml)
[![CMake on Windows MSVC/Clang x64](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows_run.yml/badge.svg?branch=main)](https://github.com/Kataglyphis/AccelerANTgine/actions/workflows/windows_run.yml)
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

Frequently tested under:
* windows server 2025 x64 *__Clang 21.1.1__* and *__MSVC__*
* [clang-cl](https://learn.microsoft.com/de-de/cpp/build/clang-support-msbuild?view=msvc-170) to compile the rust crate on windows
* ubuntu 26.04 x64 *__Clang 21.1.1__*
* ubuntu 26.04 ARM *__Clang 21.1.1__*

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
* [WebRTC](https://webrtc.org/) — realtime transport
* [nlohmann_json](https://github.com/nlohmann/json)
* [tomlplusplus](https://github.com/marzer/tomlplusplus)
* [SPDLOG](https://github.com/gabime/spdlog)
* [nanobind](https://github.com/wjakob/nanobind) — the Python bindings
* [gtest](https://github.com/google/googletest)
* [gbenchmark](https://github.com/google/benchmark)
* [google fuzztest](https://github.com/google/fuzztest)

##### Optional
* [Rust](https://www.rust-lang.org/)
* [corrision-rs](https://github.com/corrosion-rs/corrosion)
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
  
  For now the features in Rust are experimental. If you want to use them install  
  Rust and set `RUST_FEATURES=ON` on your CMake build. In order to compile a rust 
  crate on windows u need to me MSVC ABI compatible. Therefore I use clang-cl
  in order to compile the rust crate when on windows.  
  See also file `Src\rusty_code\.cargo\config.toml`
  ```toml
  [target.x86_64-pc-windows-msvc.cc]
  path = "clang-cl"

  [target.x86_64-pc-windows-msvc.cxx]
  path = "clang-cl"
  ```

  (for clarity: Assumption you are in the dir you have cloned the repo into)
  ```sh
  $ mkdir build ; cd build
  # enlisting all available presets
  $ cmake --list-presets=all ../
  $ cmake --preset <configurePreset-name> ../
  $ cmake --build --preset <buildPreset-name> .
  ```

On Windows, through the same script CI runs:

```powershell
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1 -BuildTargets clangcl-debug -LogDir C:\b\logs
```

Build directories and presets are rows in
`scripts/windows/Build-Windows.config.psd1`, not parameters; each row also names
an environment variable that overrides it.

### Python bindings

The library is also exposed to Python through nanobind: the module lives in
`Bindings/python` (`kataglyphis_inference`), its tests in `Test/python`, and
`scripts/windows/Build-PythonBindings.ps1` (or `Invoke-ContainerPythonBindings.ps1`, which
runs it inside the ANTfrastructure Windows image) builds and tests it on Windows.

### Upgrades

#### What is behind: Renovate as a local CLI

```bash
bash scripts/linux/renovate-local.sh                     # report (default: git-submodules)
bash scripts/linux/renovate-local.sh --managers pep621   # the pyproject pins
bash scripts/linux/renovate-local.sh --apply --dry-run   # the plan
bash scripts/linux/renovate-local.sh --apply             # move the gitlinks
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

1. Compilation Test Suite: This suite gets executed every compilation step. This ensures the very most important functionality is correct before every compilation.

2. Commit Test Suite: This gets executed on every push. More expensive tests are allowed :) 

3. Perf test suite: It is all about measurements of performance. We are C++ tho! 

4. Fuzz testing suite

5. Python bindings test suite (`Test/python`), run against the built `kataglyphis_inference` module.

## Performance tests

`ci-profile-bench.sh` is the profiling and benchmark lane, and it is what CI
runs:

```bash
bash scripts/linux/ci-profile-bench.sh
```

It needs gperftools (`google-perftools`, `libgoogle-perftools-dev`), `graphviz`
and, for the flame graphs, Go's `pprof`; `valgrind --tool=callgrind` is reached
through `bash scripts/linux/ci-release.sh --callgrind`, and `perf record` needs
`linux-tools-$(uname -r)`. Installing them is not this project's subject — the
upstream install instructions for
[gperftools](https://github.com/gperftools/gperftools),
[pprof](https://github.com/google/pprof),
[valgrind](https://valgrind.org/docs/manual/cl-manual.html) and
[perf](https://perfwiki.github.io/main/) are the ones that stay correct, and the
CI image already carries the set.

## Static analysis and formatting

One entry point per platform, and CI runs exactly these:

```bash
bash scripts/linux/run-static-analysis-format.sh
```

```powershell
pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
```

They cover cmake-format, clang-format, clang-tidy, `clang++ --analyze` and
`scan-build`, over the files the project actually compiles (`.ixx`, `.cppm` and
`.mxx` included). Every one of them is a gate: a tool that is not installed
fails the lane rather than being skipped.

`.clang-format`, `.clang-tidy` and `.cmake-format.yaml` here are **shared**
configs, and `scripts/linux/run-lint-gates.sh` checks them against
ANTfrastructure's copies — edit them upstream, not here. What each tool does and
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
* [corrision-rs](https://github.com/corrosion-rs/corrosion)
* [cxx](https://cxx.rs/)
* [C++ Software Design by Klaus Iglberger](https://meetingcpp.com/2024/Speaker/items/Klaus_Iglberger.html)
