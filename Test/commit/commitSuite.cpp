#include <gtest/gtest.h>

#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

// Demonstrate some basic assertions.
TEST(HelloTestCommit, BasicAssertions)
{

    // Expect two strings not to be equal.
    EXPECT_STRNE("hello", "world");
    // Expect equality.
    EXPECT_EQ(7 * 6, 42);
}

TEST(Integration, VulkanEngine) { EXPECT_EQ(7 * 6, 42); }