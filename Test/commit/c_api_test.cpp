#include "kataglyphis_c_api.h"
#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <array>
#include <climits>
#include <cstddef>
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

namespace {

struct Collected
{
    std::string text;
    kataglyphis_text_generator *cancel_after_first = nullptr;
};

void collect(const char *piece, std::size_t length, void *user_data)
{
    auto *collected = static_cast<Collected *>(user_data);
    collected->text.append(piece, length);
    if (collected->cancel_after_first != nullptr) { kataglyphis_text_generator_cancel(collected->cancel_after_first); }
}

auto tiny_generator() -> kataglyphis_text_generator *
{
    kataglyphis_text_generator *generator = nullptr;
    EXPECT_EQ(kataglyphis_text_generator_create(
                kataglyphis::test::tiny_genai_model_dir().string().c_str(), KATAGLYPHIS_TEXT_PROVIDER_CPU, &generator),
      KATAGLYPHIS_TEXT_OK);
    return generator;
}

auto four_tokens() -> kataglyphis_text_options
{
    kataglyphis_text_options options{};
    kataglyphis_text_options_default(&options);
    options.max_new_tokens = 4;
    return options;
}

constexpr kataglyphis_text_message kUser{ "user", "abc" };

}// namespace

TEST(CTextApi, GeneratesThroughTheCallbackAndReportsStats)
{
    auto *generator = tiny_generator();
    ASSERT_NE(generator, nullptr);
    Collected collected;
    kataglyphis_text_stats stats{};
    const auto options = four_tokens();
    EXPECT_EQ(kataglyphis_text_generator_generate(generator, &kUser, 1, &options, collect, &collected, &stats),
      KATAGLYPHIS_TEXT_OK);
    EXPECT_EQ(collected.text, "defg");
    EXPECT_EQ(stats.completion_tokens, 4U);
    EXPECT_EQ(stats.finish_reason, KATAGLYPHIS_TEXT_FINISH_LENGTH);
    EXPECT_EQ(kataglyphis_text_generator_generate(generator, &kUser, 1, &options, nullptr, nullptr, nullptr),
      KATAGLYPHIS_TEXT_OK);
    kataglyphis_text_generator_destroy(generator);
}

TEST(CTextApi, CancelInsideTheCallbackStopsAfterOneToken)
{
    auto *generator = tiny_generator();
    ASSERT_NE(generator, nullptr);
    Collected collected{ {}, generator };
    kataglyphis_text_stats stats{};
    const auto options = four_tokens();
    EXPECT_EQ(kataglyphis_text_generator_generate(generator, &kUser, 1, &options, collect, &collected, &stats),
      KATAGLYPHIS_TEXT_OK);
    EXPECT_EQ(collected.text, "d");
    EXPECT_EQ(stats.finish_reason, KATAGLYPHIS_TEXT_FINISH_CANCELLED);
    kataglyphis_text_generator_destroy(generator);
}

TEST(CTextApi, RejectsMissingArgumentsAndReportsLoadFailures)
{
    kataglyphis_text_generator *generator = nullptr;
    EXPECT_EQ(kataglyphis_text_generator_create(nullptr, KATAGLYPHIS_TEXT_PROVIDER_CPU, &generator),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    EXPECT_EQ(kataglyphis_text_generator_create(
                kataglyphis::test::tiny_genai_model_dir().string().c_str(), KATAGLYPHIS_TEXT_PROVIDER_CPU, nullptr),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    EXPECT_EQ(
      kataglyphis_text_generator_create(kataglyphis::test::tiny_genai_model_dir().string().c_str(), 99, &generator),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    EXPECT_EQ(kataglyphis_text_generator_create("/nonexistent-genai-model", KATAGLYPHIS_TEXT_PROVIDER_CPU, &generator),
      KATAGLYPHIS_TEXT_MODEL_LOAD_FAILED);
    EXPECT_EQ(generator, nullptr);
    auto *ready = tiny_generator();
    ASSERT_NE(ready, nullptr);
    const auto options = four_tokens();
    const kataglyphis_text_message no_content{ "user", nullptr };
    EXPECT_EQ(kataglyphis_text_generator_generate(ready, &kUser, 1, nullptr, nullptr, nullptr, nullptr),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    EXPECT_EQ(kataglyphis_text_generator_generate(ready, &no_content, 1, &options, nullptr, nullptr, nullptr),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    EXPECT_EQ(kataglyphis_text_generator_generate(ready, &kUser, 0, &options, nullptr, nullptr, nullptr),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    EXPECT_EQ(kataglyphis_text_generator_generate(nullptr, &kUser, 1, &options, nullptr, nullptr, nullptr),
      KATAGLYPHIS_TEXT_INVALID_ARGUMENT);
    kataglyphis_text_generator_cancel(nullptr);
    kataglyphis_text_generator_destroy(nullptr);
    kataglyphis_text_generator_destroy(ready);
}
