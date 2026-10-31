#!/usr/bin/env bash
# Compiles the real demo-device selection for each supported package variant.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cat > "$work/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.24)
project(demo_device LANGUAGES CXX)
include("${MODULE}")
enable_testing()
function(check_device name variant system expected)
  add_executable(${name} main.cpp)
  target_compile_features(${name} PRIVATE cxx_std_17)
  target_include_directories(${name} PRIVATE "${DEMO_SRC}")
  accelerantgine_configure_demo_device(${name} "${variant}" "${system}")
  add_test(NAME ${name} COMMAND ${name} "${expected}")
endfunction()
check_device(cpu_linux cpu Linux cpu)
check_device(cpu_windows cpu Windows cpu)
check_device(nvidia_linux nvidia Linux cuda)
check_device(nvidia_windows nvidia Windows cuda)
check_device(amd_linux amd Linux migraphx)
check_device(amd_windows amd Windows directml)
CMAKE
cat > "$work/main.cpp" <<'CPP'
#include "demo_device.hpp"
#include <string_view>
enum class Provider { Cpu, Cuda, MigraphX, DirectML };
int main(int argc, char **argv) {
    using kataglyphis::demo::default_device;
    using kataglyphis::demo::parse_device;
    if (argc != 2 || default_device != std::string_view(argv[1])) return 1;
    if (!parse_device<Provider>(default_device)) return 2;
    if (parse_device<Provider>("cpu") != Provider::Cpu) return 3;
    if (parse_device<Provider>("cuda") != Provider::Cuda) return 4;
    if (parse_device<Provider>("migraphx") != Provider::MigraphX) return 5;
    if (parse_device<Provider>("directml") != Provider::DirectML) return 6;
    if (parse_device<Provider>("unknown")) return 7;
    return 0;
}
CPP
cmake -S "$work" -B "$work/build" "-DMODULE=$root/cmake/OrtPackageVariant.cmake" "-DDEMO_SRC=$root/Src"
cmake --build "$work/build" --parallel 2
ctest --test-dir "$work/build" --output-on-failure
