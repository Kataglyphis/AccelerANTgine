#include "kataglyphis_c_api.h"

#include <gtest/gtest.h>

#include <array>
#include <climits>
#include <string>

import kataglyphis.inference;

namespace {

// Every pair whose sum fits in an int, so no case relies on signed overflow.
constexpr std::array<std::array<int, 2>, 7> kOperands{
    { { 0, 0 }, { 2, 3 }, { -10, 4 }, { -7, -8 }, { INT_MAX, 0 }, { INT_MIN, INT_MAX }, { INT_MAX, INT_MIN + 1 } }
};

}// namespace

TEST(CApi, AddsTwoIntegers)
{
    EXPECT_EQ(kataglyphis_add(2, 3), 5);
    EXPECT_EQ(kataglyphis_add(-10, 4), -6);
    EXPECT_EQ(kataglyphis_add(INT_MIN, INT_MAX), -1);
}

TEST(CApi, AdditionIsCommutativeWithZeroAsIdentity)
{
    for (const auto &[lhs, rhs] : kOperands) {
        EXPECT_EQ(kataglyphis_add(lhs, rhs), kataglyphis_add(rhs, lhs)) << lhs << " + " << rhs;
        EXPECT_EQ(kataglyphis_add(lhs, 0), lhs);
        EXPECT_EQ(kataglyphis_add(0, rhs), rhs);
    }
}

TEST(MyCalculator, AgreesWithTheCApi)
{
    const kataglyphis::inference::MyCalculator calculator;
    for (const auto &[lhs, rhs] : kOperands) {
        EXPECT_EQ(calculator.add(lhs, rhs), kataglyphis_add(lhs, rhs)) << lhs << " + " << rhs;
    }
}

TEST(MyCalculator, VersionIsTheProjectsMajorDotMinor)
{
    const kataglyphis::inference::MyCalculator calculator;
    EXPECT_EQ(calculator.version(), std::string(KATAGLYPHIS_TEST_PROJECT_VERSION));
}
