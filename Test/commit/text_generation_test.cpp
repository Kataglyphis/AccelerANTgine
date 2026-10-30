#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

import kataglyphis.text_generation;
import nlohmann.json;

namespace text = kataglyphis::text;

namespace {

const std::filesystem::path kModelDir = kataglyphis::test::tiny_genai_model_dir();

struct Oracle
{
    std::string prompt;
    std::string continuation;
    std::vector<std::int32_t> ids;
};

// The generator's own expectation, so no number is retyped here.
auto oracle() -> Oracle
{
    std::ifstream stream(kModelDir / "fixture.json");
    const auto fixture = nlohmann::json::parse(stream);
    return { fixture.at("prompt").get<std::string>(),
        fixture.at("continuation").get<std::string>(),
        fixture.at("continuation_ids").get<std::vector<std::int32_t>>() };
}

auto user(std::string content) -> std::vector<text::ChatMessage> { return { { "user", std::move(content) } }; }

auto budget(std::size_t tokens) -> text::GenerationOptions
{
    text::GenerationOptions options;
    options.max_new_tokens = static_cast<int>(tokens);
    return options;
}

class TextGeneration : public ::testing::Test
{
  protected:
    void SetUp() override { ASSERT_TRUE(generator.initialize(kModelDir).has_value()); }

    text::TextGenerator generator;
    Oracle expected = oracle();
};

// U+00FF is the bytes C3 BF: greedy decoding counts from 0xBF to 0xFF, then emits the end token.
constexpr std::string_view kNearTheEnd = "\xC3\xBF";
constexpr std::size_t kTokensToTheEnd = 0x100 - 0xBF;

}// namespace

TEST_F(TextGeneration, GreedyDecodingYieldsTheFixtureContinuation)
{
    const auto result = generator.generate(user(expected.prompt), budget(expected.ids.size()));
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->tokens, expected.ids);
    EXPECT_EQ(result->text, expected.continuation);
    EXPECT_EQ(result->prompt_tokens, expected.prompt.size());
    EXPECT_EQ(result->finish_reason, text::FinishReason::Length);
    EXPECT_GE(result->time_to_first_token_ms, 0.0);
    EXPECT_GT(result->decode_tokens_per_second, 0.0);
}

TEST_F(TextGeneration, StreamsEveryPieceInOrder)
{
    std::vector<std::string> pieces;
    const auto result = generator.generate(user(expected.prompt),
      budget(expected.ids.size()),
      [&pieces](std::string_view piece) { pieces.emplace_back(piece); });
    ASSERT_TRUE(result.has_value());
    std::string joined;
    for (const auto &piece : pieces) { joined += piece; }
    EXPECT_EQ(joined, expected.continuation);
    EXPECT_EQ(pieces.size(), expected.ids.size());
}

TEST_F(TextGeneration, TheChatTemplateJoinsEveryMessage)
{
    const std::vector<text::ChatMessage> messages{ { "system", expected.prompt.substr(0, 2) },
        { "user", expected.prompt.substr(2) } };
    const auto result = generator.generate(messages, budget(expected.ids.size()));
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->prompt_tokens, expected.prompt.size());
    EXPECT_EQ(result->text, expected.continuation);
}

TEST_F(TextGeneration, TheEndTokenStopsBeforeTheBudget)
{
    const auto result = generator.generate(user(std::string(kNearTheEnd)), budget(kTokensToTheEnd + 10));
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->tokens.size(), kTokensToTheEnd);
    EXPECT_EQ(result->tokens.front(), 0xC0);
    EXPECT_EQ(result->tokens.back(), 0x100);
    EXPECT_EQ(result->finish_reason, text::FinishReason::Stop);
}

TEST_F(TextGeneration, CancelFromTheCallbackEndsAfterTheCurrentToken)
{
    const auto result = generator.generate(user(expected.prompt),
      budget(expected.ids.size()),
      [this](std::string_view /*piece*/) { generator.request_cancel(); });
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->tokens.size(), 1U);
    EXPECT_EQ(result->finish_reason, text::FinishReason::Cancelled);
}

TEST_F(TextGeneration, CancelFromAnotherThreadIsObserved)
{
    std::atomic<bool> first_piece{ false };
    std::atomic<bool> cancelled{ false };
    std::expected<text::GenerationResult, text::TextGenError> result =
      std::unexpected(text::TextGenError::NotInitialized);
    std::thread worker([&] {
        result = generator.generate(user(expected.prompt), budget(expected.ids.size()), [&](std::string_view) {
            first_piece.store(true);
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
            while (!cancelled.load() && std::chrono::steady_clock::now() < deadline) { std::this_thread::yield(); }
        });
    });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!first_piece.load() && std::chrono::steady_clock::now() < deadline) { std::this_thread::yield(); }
    generator.request_cancel();
    cancelled.store(true);
    worker.join();
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->finish_reason, text::FinishReason::Cancelled);
    EXPECT_EQ(result->tokens.size(), 1U);
}

TEST_F(TextGeneration, EmptyMessagesOrNoBudgetAreInvalid)
{
    EXPECT_EQ(kataglyphis::test::error_of(generator.generate({}, budget(1))), text::TextGenError::InvalidOptions);
    EXPECT_EQ(kataglyphis::test::error_of(generator.generate(user(expected.prompt), budget(0))),
      text::TextGenError::InvalidOptions);
}

TEST(TextGenerationSetup, TheModelLiesBesideTheSuiteForAStagedOrMovedBuild)
{
    const auto beside = kataglyphis::test::executable_dir();
    EXPECT_TRUE(beside.is_absolute()) << beside;
    EXPECT_TRUE(std::filesystem::exists(beside / "test-models" / "tiny-genai" / "genai_config.json")) << beside;
}

TEST(TextGenerationSetup, AnUninitializedGeneratorRefuses)
{
    text::TextGenerator generator;
    EXPECT_FALSE(generator.is_initialized());
    EXPECT_EQ(
      kataglyphis::test::error_of(generator.generate(user("a"), budget(1))), text::TextGenError::NotInitialized);
}

TEST(TextGenerationSetup, AMissingModelDirectoryFailsToLoad)
{
    text::TextGenerator generator;
    EXPECT_EQ(
      kataglyphis::test::error_of(generator.initialize(kModelDir / "absent")), text::TextGenError::ModelLoadFailed);
    EXPECT_FALSE(generator.is_initialized());
}

TEST(TextGenerationSetup, EveryErrorHasItsOwnMessage)
{
    std::set<std::string_view> messages;
    for (const auto error : { text::TextGenError::LibraryUnavailable,
           text::TextGenError::ModelLoadFailed,
           text::TextGenError::ProviderUnavailable,
           text::TextGenError::TokenizerFailed,
           text::TextGenError::ChatTemplateFailed,
           text::TextGenError::EncodeFailed,
           text::TextGenError::InvalidOptions,
           text::TextGenError::GenerationFailed,
           text::TextGenError::NotInitialized }) {
        EXPECT_FALSE(text::to_string(error).empty());
        messages.insert(text::to_string(error));
    }
    EXPECT_EQ(messages.size(), 9U);
}
