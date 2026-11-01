// ModelANT's text-generation-v1 on the released SmolLM2-135M; built only where CI fetched resources/models/llm.lock.
#include "kataglyphis_c_api.h"

#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

import kataglyphis.text_generation;
import nlohmann.json;

namespace text = kataglyphis::text;

extern "C" int kataglyphis_text_contract_c(const char *model_dir,
  const kataglyphis_text_message *message,
  std::int32_t max_new_tokens,
  std::int32_t *ids,
  std::size_t id_capacity,
  char *text,
  std::size_t text_size,
  kataglyphis_text_stats *stats);

namespace {

struct ContractCase
{
    std::string role;
    std::string content;
    int max_new_tokens{};
    std::string must_contain;
    std::vector<std::int32_t> expected_ids;
};

// The release's own numbers, read from the ModelANT pin; the test retypes them once to catch a silent contract change.
auto capital_of_france() -> ContractCase
{
    std::ifstream stream(KATAGLYPHIS_TEXT_CONTRACT);
    const auto contract = nlohmann::json::parse(stream);
    const auto &cases = contract.at("cases");
    EXPECT_EQ(cases.size(), 1U);
    const auto &found = cases.at(0);
    EXPECT_EQ(found.at("name").get<std::string>(), "capital-of-france");
    EXPECT_EQ(found.at("model").get<std::string>(), "smollm2_135m_instruct-cpu");
    EXPECT_EQ(found.at("messages").size(), 1U);
    const auto &message = found.at("messages").at(0);
    return { message.at("role").get<std::string>(),
        message.at("content").get<std::string>(),
        found.at("max_new_tokens").get<int>(),
        found.at("must_contain").get<std::string>(),
        found.at("expected_ids").get<std::vector<std::int32_t>>() };
}

const std::vector<std::int32_t> kReleasedIds{ 504, 3575, 282, 4649, 314, 7042, 30, 2 };

}// namespace

TEST(TextContract, CapitalOfFranceDecodesTheReleasedTokensThroughCpp)
{
    const auto contract = capital_of_france();
    ASSERT_EQ(contract.expected_ids, kReleasedIds);
    text::TextGenerator generator;
    ASSERT_TRUE(generator.initialize(KATAGLYPHIS_TEXT_CONTRACT_MODEL).has_value());
    text::GenerationOptions options;
    options.max_new_tokens = contract.max_new_tokens;
    // Greedy decoding ignores it; a mutant that samples instead then fails the same way on every run.
    options.seed = 1;
    const auto result = generator.generate({ { contract.role, contract.content } }, options);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->tokens, kReleasedIds);
    EXPECT_NE(result->text.find(contract.must_contain), std::string::npos) << result->text;
    EXPECT_EQ(result->finish_reason, text::FinishReason::Stop);
}

TEST(TextContract, CapitalOfFranceDecodesTheReleasedTokensThroughC)
{
    const auto contract = capital_of_france();
    ASSERT_EQ(contract.expected_ids, kReleasedIds);
    const kataglyphis_text_message message{ contract.role.c_str(), contract.content.c_str() };
    std::vector<std::int32_t> ids(kReleasedIds.size() + 1, -1);
    std::array<char, 256> reply{};
    kataglyphis_text_stats stats{};
    ASSERT_EQ(kataglyphis_text_contract_c(KATAGLYPHIS_TEXT_CONTRACT_MODEL,
                &message,
                contract.max_new_tokens,
                ids.data(),
                ids.size(),
                reply.data(),
                reply.size(),
                &stats),
      KATAGLYPHIS_TEXT_OK);
    ASSERT_EQ(stats.completion_tokens, kReleasedIds.size());
    ids.resize(stats.completion_tokens);
    EXPECT_EQ(ids, kReleasedIds);
    EXPECT_NE(std::string(reply.data()).find(contract.must_contain), std::string::npos) << reply.data();
    EXPECT_EQ(stats.finish_reason, KATAGLYPHIS_TEXT_FINISH_STOP);
}
