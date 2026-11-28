#include "usable_cpus.hpp"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "kUsableCpusContract.inc"

import nlohmann.json;

namespace {

namespace usable = kataglyphis::inference::usable_cpus;

using Levels = std::vector<std::optional<std::string>>;

// A cgroup root holding each relative directory's cpu.max, and a /proc/self/cgroup naming `membership`; gone with it.
class FakeTree
{
  public:
    FakeTree(std::string_view name,
      std::string_view membership,
      const std::vector<std::pair<std::string, std::string>> &limits)
      : base_(std::filesystem::temp_directory_path() / "usable_cpus_test" / name)
    {
        std::filesystem::remove_all(base_);
        for (const auto &[relative, text] : limits) {
            const auto dir = root() / relative;
            std::filesystem::create_directories(dir);
            std::ofstream(dir / "cpu.max") << text << '\n';
        }
        std::filesystem::create_directories(base_);
        std::ofstream(proc()) << membership;
    }
    ~FakeTree()
    {
        std::error_code ignored;
        std::filesystem::remove_all(base_, ignored);
    }
    FakeTree(const FakeTree &) = delete;
    auto operator=(const FakeTree &) -> FakeTree & = delete;

    [[nodiscard]] auto root() const -> std::filesystem::path { return base_ / "cgroup"; }
    [[nodiscard]] auto proc() const -> std::filesystem::path { return base_ / "proc-self-cgroup"; }

  private:
    std::filesystem::path base_;
};

TEST(UsableCpus, EveryHubCaseGivesItsUsableCount)
{
    const auto contract = nlohmann::json::parse(kUsableCpusContract, nullptr, false);
    ASSERT_FALSE(contract.is_discarded());
    ASSERT_EQ(contract["schema_version"].get<int>(), 1) << "a new schema needs a new reader";
    ASSERT_FALSE(contract["cases"].empty());
    for (const auto &item : contract["cases"]) {
        Levels cpu_max;
        for (const auto &level : item["cpu_max"]) {
            cpu_max.push_back(level.is_null() ? std::nullopt : std::optional<std::string>(level.get<std::string>()));
        }
        EXPECT_EQ(usable::usable_of(item["affinity"].get<int>(), cpu_max), item["expect"]["usable"].get<int>())
          << item["name"].get<std::string>();
    }
}

TEST(UsableCpus, AZeroPeriodOrAMalformedTextSetsNoLimit)
{
    EXPECT_EQ(usable::usable_of(4, Levels{ "100000 0", "fifty 100000", "200000" }), 4);
    EXPECT_EQ(usable::usable_of(4, Levels{ "200000 100000\n" }), 2);
}

TEST(UsableCpus, TheWalkReadsFromTheOwnCgroupUpToTheRoot)
{
    const FakeTree tree(
      "walk", "12:cpu:/v1\n0::/user.slice/app\n", { { "user.slice/app", "max 100000" }, { ".", "400000 100000" } });
    EXPECT_EQ(
      usable::cgroup_cpu_max(tree.root(), tree.proc()), (Levels{ "max 100000", std::nullopt, "400000 100000" }));
}

TEST(UsableCpus, ACgroupOutsideTheNamespaceReadsOnlyItsRoot)
{
    const FakeTree tree("outside", "0::/../../other\n", { { ".", "200000 100000" } });
    EXPECT_EQ(usable::cgroup_cpu_max(tree.root(), tree.proc()), (Levels{ "200000 100000" }));
}

TEST(UsableCpus, NoCgroupV2LineAndNoProcFileReadNothing)
{
    const FakeTree tree("v1", "4:cpu,cpuacct:/docker/1\n", { { ".", "100000 100000" } });
    EXPECT_TRUE(usable::cgroup_cpu_max(tree.root(), tree.proc()).empty());
    EXPECT_TRUE(usable::cgroup_cpu_max(tree.root(), tree.root() / "missing").empty());
}

}// namespace
