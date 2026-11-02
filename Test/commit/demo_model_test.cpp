#include "demo_model.hpp"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <random>
#include <string>

namespace fs = std::filesystem;

namespace {
struct PackageTree
{
    fs::path root;
    PackageTree()
    {
        std::random_device device;
        root = fs::temp_directory_path() / ("kataglyphis-demo-model-" + std::to_string(device()));
        fs::create_directories(root / "bin");
        fs::create_directories(root / "share/models");
    }
    ~PackageTree()
    {
        std::error_code error;
        fs::remove_all(root, error);
    }
};
}// namespace

using kataglyphis::demo::default_model_from_executable;

TEST(DemoModel, TheConfiguredFileIsLookedUpInThePackageDirectory)
{
    const PackageTree tree;
    const fs::path configured = "models/other_detector.onnx";
    const auto executable = tree.root / "bin/demo";
    std::ofstream(tree.root / "share/models/other_detector.onnx") << "x";
    const auto found = default_model_from_executable(executable, false, true, configured, "../lib", "../share/models");
    EXPECT_EQ(found, tree.root / "bin/../share/models/other_detector.onnx");
}

TEST(DemoModel, AnUnpackagedDemoUsesTheConfiguredPathAsItIs)
{
    const PackageTree tree;
    const fs::path configured = "models/other_detector.onnx";
    EXPECT_EQ(default_model_from_executable(tree.root / "bin/demo", false, false, configured, {}, {}), configured);
    EXPECT_EQ(default_model_from_executable({}, false, false, configured, {}, {}), configured);
}

TEST(DemoModel, APackagedDemoNeverFallsBackToTheWorkingDirectory)
{
    const PackageTree tree;
    const fs::path configured = "models/other_detector.onnx";
    EXPECT_TRUE(default_model_from_executable({}, false, true, configured, "../lib", "../share/models").empty());
    const auto missing =
      default_model_from_executable(tree.root / "bin/demo", false, true, configured, "../lib", "../share/models");
    EXPECT_EQ(missing.filename(), configured.filename());
    EXPECT_TRUE(missing.is_absolute());
}
