<h1 align="center">
  <br>
  <a href="https://jonasheinle.de"><img src="images/logo.png" alt="logo" width="200"></a>
  <br>
  CMake/C++ template project
  <br>
</h1>



<!-- <h1 align="center">
  <br>
  <a href="https://jonasheinle.de"><img src="images/vulkan-logo.png" alt="VulkanEngine" width="200"></a>
  <a href="https://jonasheinle.de"><img src="images/Engine_logo.png" alt="VulkanEngine" width="200"></a>
  <a href="https://jonasheinle.de"><img src="images/glm_logo.png" alt="VulkanEngine" width="200"></a>
</h1> -->

<h4 align="center">This CMake/C++ template project gives me a good starting point for f.e. GPU/Graphics programming. For everything close to hardware ...  <a href="https://jonasheinle.de" target="_blank"></a>.</h4>

For the official docs follow this [link](https://cmaketemplate.jonasheinle.de/).

[![Linux run on ARM/GCC/Clang](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/linux_run_arm.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/linux_run_arm.yml)
[![Linux run on x86/GCC/Clang](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/linux_run_x86.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/linux_run_x86.yml)
[![CMake on Windows MSVC x64](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/windows_run.yml/badge.svg?branch=main)](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/windows_run.yml)
[![CodeQL](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/github-code-scanning/codeql)
[![Automatic Dependency Submission](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/dependency-graph/auto-submission/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-CMakeTemplate/actions/workflows/dependency-graph/auto-submission)
<!-- [![Linux build](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Linux.yml/badge.svg)](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Linux.yml)
[![Windows build](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Windows.yml/badge.svg)](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Windows.yml)
[![TopLang](https://img.shields.io/github/languages/top/Kataglyphis/GraphicsEngineVulkan)]() -->
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)
[![Twitter](https://img.shields.io/twitter/follow/Cataglyphis_?style=social)](https://twitter.com/Cataglyphis_)

<p align="center">
  <a href="#about-the-project">About The Project</a> •
  <a href="#getting-started">Getting Started</a> •
  <a href="#license">License</a> •
  <a href="#literature">Literature</a>
</p>

<!-- TABLE OF CONTENTS -->
<details open="open">
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#key-features">Key Features</a></li>
      </ul>
      <ul>
        <li><a href="#dependencies">Dependencies</a></li>
      </ul>
      <ul>
        <li><a href="#useful-tools">Useful tools</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#tests">Tests</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgements">Acknowledgements</a></li>
    <li><a href="#literature">Literature</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

<!-- <h1 align="center">
  <br>
  <a href="https://jonasheinle.de"><img src="images/Screenshot1.png" alt="VulkanEngine" width="400"></a>
  <a href="https://jonasheinle.de"><img src="images/Screenshot2.png" alt="VulkanEngine" width="400"></a>
  <a href="https://jonasheinle.de"><img src="images/Screenshot3.png" alt="VulkanEngine" width="700"></a>
</h1> -->

<!-- [![Kataglyphis Engine][product-screenshot1]](https://jonasheinle.de)
[![Kataglyphis Engine][product-screenshot2]](https://jonasheinle.de)
[![Kataglyphis Engine][product-screenshot3]](https://jonasheinle.de) -->

This project is dedicated to compiling a comprehensive collection of best practices for C++ development using CMake. It serves as a definitive guide for starting new C++ projects, providing insights into optimal project setup, modern CMake techniques, and efficient workflows. The repository includes examples, templates, and detailed instructions to help developers of all levels adopt industry standards and improve their project configuration and build processes.

Frequently tested under   
* windows server 2025 x64 *__Clang 21.1.1__* and *__MSVC__*
* [clang-cl](https://learn.microsoft.com/de-de/cpp/build/clang-support-msbuild?view=msvc-170) to compile the rust crate on windows
* ubuntu 24.04 x64 *__Clang 18.1.3__*
* ubuntu 24.04 ARM *__Clang 18.1.3__*

### Key Features

<div align="center">

| Category            | Feature                      | Implement Status |
|---------------------|------------------------------|:----------------:|
| Build System        | CMake > 4.1                  |        ✔️        |
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
* [nlohmann_json](https://github.com/nlohmann/json)
* [SPDLOG](https://github.com/gabime/spdlog)
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
**CMake 4.1.1** or higher required.<br />

### Installation

1. Clone the repo
   ```sh
   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-CMakeTemplate.git
   ```
   > **_NOTE:_** In case you forgot the flag --recurse run the following command  
   ```sh
   git submodule update --init --recursive

   ```
   afterwards.
3. Optional: Using the newest clang compiler. Install via apt. See [here](https://apt.llvm.org/):
4. Optional: Run `scripts/setup-dependencies.sh` for preparing important dev tools. 
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

### Upgrades
#### Rusty things:
1. Do not forget to upgrade the cxxbridge from time to time:
```bash
cargo install cxxbridge-cmd
```

# Tests
I have four tests suites.

1. Compilation Test Suite: This suite gets executed every compilation step. This ensures the very most important functionality is correct before every compilation.

2. Commit Test Suite: This gets executed on every push. More expensive tests are allowed :) 

3. Perf test suite: It is all about measurements of performance. We are C++ tho! 

4. Fuzz testing suite

## Performance Tests

### gperftools and pprof
#### Install deps
> **__Linux only__**
1. Step:
```bash
sudo apt-get install google-perftools libgoogle-perftools-dev graphviz
####### only if go is not installed already 
wget https://go.dev/dl/go1.24.3.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.24.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
source ~/.bashrc
# to see if everything works
go version
####### go on with this step if go already installed
go install github.com/google/pprof@latest  # if you want to use latest Go-based pprof
export PATH="$PATH:$HOME/go/bin"
source ~/.bashrc  # or source ~/.zshrc
```

2. Step:
Run actual profiling and look into results:
```bash
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libprofiler.so CPUPROFILE=profile.prof ./build/KataglyphisCppProject
pprof -http=:8080 ./build/KataglyphisCppProject profile.prof
```

### valgrind

```bash
sudo apt install valgrind kcachegrind
# build in debug for readable information
valgrind --tool=callgrind ./build/KataglyphisCppProject
```

### perf

```bash
sudo apt install linux-tools-$(uname -r)
perf record ./build/KataglyphisCppProject
```

## Static Analyzers

```bash
clang --analyze --output-format html $(find Src -name '*.cpp' -o -name '*.cc')
scan-build cmake --build .
clang-tidy -p=./build/compile_commands.json  $(find Src -name '*.cpp' -o -name '*.cc')

```

# Format cmake files

```bash
uv venv
source .venv/bin/activate
pip install -v -e .
cmake-format -c ./.cmake-format.yaml -i $(find cmake -name '*.cmake' -o -name 'CMakeLists.txt')
```
# Format code files 

```bash
clang-format -i $(find include -name "*.cpp" -or -name "*.h" -or -name "*.hpp")
```

Use clang-format as a pre-commit hook like this.
```bash
uv venv
source .venv/bin/activate # .venv/Scripts/activate on pwsh
uv pip install pre-commit
pre-commit install
# run on all files once (optional)
pre-commit run --all-files
```


# Docs
Build the docs
```bash
uv venv
source .venv/bin/activate
pip install -r requirements.txt
cd docs 
make html
```

<!-- ROADMAP -->
## Roadmap
Upcoming :)
<!-- See the [open issues](https://github.com/othneildrew/Best-README-Template/issues) for a list of proposed features (and known issues). -->



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

<!-- CONTACT -->
## Contact

Jonas Heinle - [@Cataglyphis_](https://twitter.com/Cataglyphis_) - jonasheinle@googlemail.com

[jonasheinle.de](https://jonasheinle.de/#/landingPage)
<!-- ACKNOWLEDGEMENTS -->
## Acknowledgements

<!-- Thanks for free 3D Models: 
* [Morgan McGuire, Computer Graphics Archive, July 2017 (https://casual-effects.com/data)](http://casual-effects.com/data/)
* [Viking room](https://sketchfab.com/3d-models/viking-room-a49f1b8e4f5c4ecf9e1fe7d81915ad38) -->

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
