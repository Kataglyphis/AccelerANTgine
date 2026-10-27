#include <gtest/gtest.h>

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

import kataglyphis.log;

namespace klog = kataglyphis::log;

namespace {

// Restores the process-wide threshold and sink, which every other test shares.
class LogLevelTest : public ::testing::Test
{
  protected:
    void SetUp() override { saved_ = klog::level(); }
    void TearDown() override
    {
        klog::set_sink({});
        klog::set_level(saved_);
    }

    std::vector<std::pair<klog::Level, std::string>> captured_;

    void capture()
    {
        klog::set_sink([this](klog::Level level, std::string_view message) -> void {
            captured_.emplace_back(level, std::string(message));
        });
    }

  private:
    klog::Level saved_{ klog::Level::Warning };
};

}// namespace

TEST(Log, ReleaseBuildsDefaultToWarningsAndDebugBuildsToEverything)
{
#if defined(NDEBUG)
    EXPECT_EQ(klog::build_default_level(), klog::Level::Warning);
#else
    EXPECT_EQ(klog::build_default_level(), klog::Level::Debug);
#endif
}

TEST(Log, ParsesEveryLevelNameCaseInsensitively)
{
    EXPECT_EQ(klog::parse_level("debug"), klog::Level::Debug);
    EXPECT_EQ(klog::parse_level("INFO"), klog::Level::Info);
    EXPECT_EQ(klog::parse_level("Warning"), klog::Level::Warning);
    EXPECT_EQ(klog::parse_level("error"), klog::Level::Error);
    EXPECT_EQ(klog::parse_level("off"), klog::Level::Off);
    EXPECT_FALSE(klog::parse_level("verbose").has_value());
    EXPECT_FALSE(klog::parse_level("").has_value());
    EXPECT_FALSE(klog::parse_level("debugx").has_value());
}

TEST(Log, TheEnvironmentOverridesTheBuildDefaultOnlyWithAValidLevel)
{
    EXPECT_EQ(klog::level_from_environment(std::nullopt), klog::build_default_level());
    EXPECT_EQ(klog::level_from_environment("nonsense"), klog::build_default_level());
    EXPECT_EQ(klog::level_from_environment("error"), klog::Level::Error);
    EXPECT_EQ(klog::level_from_environment("DEBUG"), klog::Level::Debug);
}

TEST_F(LogLevelTest, TheReleaseThresholdDropsDebugAndInfoButKeepsWarningsAndErrors)
{
    capture();
    klog::set_level(klog::Level::Warning);
    klog::debug("pipeline {}", "description");
    klog::info("state {} -> {}", 1, 2);
    klog::warning("fallback {}", "webrtcbin");
    klog::error("failed {}", 7);

    ASSERT_EQ(captured_.size(), 2U);
    EXPECT_EQ(captured_[0].first, klog::Level::Warning);
    EXPECT_EQ(captured_[0].second, "fallback webrtcbin");
    EXPECT_EQ(captured_[1].first, klog::Level::Error);
    EXPECT_EQ(captured_[1].second, "failed 7");
}

TEST_F(LogLevelTest, TheDebugThresholdKeepsEveryMessage)
{
    capture();
    klog::set_level(klog::Level::Debug);
    klog::debug("a");
    klog::info("b");
    klog::warning("c");
    klog::error("d");
    EXPECT_EQ(captured_.size(), 4U);
    EXPECT_TRUE(klog::enabled(klog::Level::Debug));
}

TEST_F(LogLevelTest, OffSilencesEverything)
{
    capture();
    klog::set_level(klog::Level::Off);
    klog::error("e");
    klog::write(klog::Level::Off, "never");
    EXPECT_TRUE(captured_.empty());
    EXPECT_FALSE(klog::enabled(klog::Level::Error));
    EXPECT_FALSE(klog::enabled(klog::Level::Off));
}

TEST_F(LogLevelTest, AWriteBelowTheThresholdNeverReachesTheSink)
{
    capture();
    klog::set_level(klog::Level::Error);
    klog::write(klog::Level::Warning, "dropped");
    klog::write(klog::Level::Error, "kept");
    ASSERT_EQ(captured_.size(), 1U);
    EXPECT_EQ(captured_[0].second, "kept");
}
