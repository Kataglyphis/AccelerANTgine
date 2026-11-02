#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=suite-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/suite-fixture.sh"
repo=$SUITE_ROOT work=$SUITE_WORK
mkdir -p "$work/prefix/bin/models" "$work/prefix/lib/custom/accelerantgine" "$work/prefix/assets/data/accelerantgine/models" "$work/elsewhere"
cat >"$work/test.cpp" <<'CPP'
#include "demo_model.hpp"
#include <filesystem>
#include <fstream>

int main(int argc, char **argv)
{
    namespace fs = std::filesystem;
    using kataglyphis::demo::default_model_from_executable;
    if (argc != 2) { return 1; }
    const fs::path prefix = argv[1];
    const auto exe = prefix / "lib/custom/accelerantgine/AccelerANTgine_demo";
    const auto bin_exe = prefix / "bin/AccelerANTgine_demo";
    const auto linux_model = prefix / "assets/data/accelerantgine/models/deim_dfine_n_coco.onnx";
    const auto windows_model = prefix / "bin/models/deim_dfine_n_coco.onnx";
    const fs::path private_relative = "../../../assets/data/accelerantgine/models";
    const fs::path bin_relative = "../assets/data/accelerantgine/models";
    std::ofstream(linux_model) << "linux";
    std::ofstream(windows_model) << "windows";
    fs::current_path(prefix.parent_path() / "elsewhere");
    if (!fs::equivalent(default_model_from_executable(exe, false, true, "models/deim_dfine_n_coco.onnx", private_relative, bin_relative), linux_model)) { return 2; }
    if (!fs::equivalent(default_model_from_executable(bin_exe, true, true, "models/deim_dfine_n_coco.onnx", {}, {}), windows_model)) { return 3; }
    if (!fs::equivalent(default_model_from_executable(bin_exe, false, true, "models/deim_dfine_n_coco.onnx", private_relative, bin_relative), linux_model)) { return 7; }
    fs::remove(linux_model);
    if (fs::exists(default_model_from_executable(exe, false, true, "models/deim_dfine_n_coco.onnx", private_relative, bin_relative))) { return 4; }
    if (default_model_from_executable(exe, false, false, "models/deim_dfine_n_coco.onnx", private_relative, bin_relative) != "models/deim_dfine_n_coco.onnx") { return 5; }
    if (!default_model_from_executable({}, false, true, "models/deim_dfine_n_coco.onnx", {}, {}).empty()) { return 6; }
}
CPP
"${CXX:-c++}" -std=c++23 -I"$repo/Src" "$work/test.cpp" -o "$work/test"
"$work/test" "$work/prefix"
echo 'Demo model path checks passed.'
