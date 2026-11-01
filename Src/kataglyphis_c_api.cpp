module;

#include "kataglyphis_c_api.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <new>
#include <ranges>
#include <span>
#include <string>
#include <string_view>
#include <typeinfo>
#include <vector>

module kataglyphis.c_api;

import kataglyphis.text_generation;

namespace {

namespace text = kataglyphis::text;

// The header's struct stays incomplete: defining it here would attach a global-module type to this module.
struct Handle
{ text::TextGenerator generator; };

auto handle_of(kataglyphis_text_generator *opaque) -> Handle * { return reinterpret_cast<Handle *>(opaque); }

// The C codes are the C++ enum shifted by one, so 0 stays success; api_contract_test pins every pair.
auto status_of(text::TextGenError error) -> int { return static_cast<int>(error) + 1; }

auto provider_of(std::int32_t provider, text::ExecutionProvider &out) -> bool
{
    switch (provider) {
    case KATAGLYPHIS_TEXT_PROVIDER_CPU:
        out = text::ExecutionProvider::Cpu;
        return true;
    case KATAGLYPHIS_TEXT_PROVIDER_CUDA:
        out = text::ExecutionProvider::Cuda;
        return true;
    case KATAGLYPHIS_TEXT_PROVIDER_DIRECTML:
        out = text::ExecutionProvider::DirectML;
        return true;
    default:
        return false;
    }
}

auto finish_of(text::FinishReason reason) -> std::int32_t
{
    switch (reason) {
    case text::FinishReason::Length:
        return KATAGLYPHIS_TEXT_FINISH_LENGTH;
    case text::FinishReason::Cancelled:
        return KATAGLYPHIS_TEXT_FINISH_CANCELLED;
    case text::FinishReason::Stop:
        break;
    }
    return KATAGLYPHIS_TEXT_FINISH_STOP;
}

// Whether a caller's struct reaches the end of a field, so an older, shorter struct leaves it at its default.
auto covers(const kataglyphis_text_options &options, std::size_t field_end) -> bool
{ return options.struct_size >= field_end; }

auto seed_of(const kataglyphis_text_options &options, text::GenerationOptions &chosen) -> bool
{
    if (!covers(options, offsetof(kataglyphis_text_options, seed) + sizeof(options.seed)) || options.seed < 0) {
        return true;
    }
    if (options.seed > std::numeric_limits<std::int32_t>::max()) { return false; }
    chosen.seed = static_cast<std::int32_t>(options.seed);
    return true;
}

auto stop_of(const kataglyphis_text_options &options, text::GenerationOptions &chosen) -> bool
{
    if (!covers(options, offsetof(kataglyphis_text_options, stop_count) + sizeof(options.stop_count))
        || options.stop_count == 0) {
        return true;
    }
    if (options.stop == nullptr) { return false; }
    for (std::size_t i = 0; i < options.stop_count; ++i) {
        if (options.stop[i] == nullptr) { return false; }
        chosen.stop.emplace_back(options.stop[i]);
    }
    return true;
}

// The caller's token buffer, or an empty span when its struct predates it or it asked for none.
auto token_ids_of(const kataglyphis_text_options &options) -> std::span<std::int32_t>
{
    if (!covers(options, offsetof(kataglyphis_text_options, token_id_capacity) + sizeof(options.token_id_capacity))
        || options.token_ids == nullptr) {
        return {};
    }
    return { options.token_ids, options.token_id_capacity };
}

auto options_of(const kataglyphis_text_options &options, text::GenerationOptions &chosen) -> bool
{
    if (options.struct_size < KATAGLYPHIS_TEXT_OPTIONS_V1_SIZE) { return false; }
    chosen.max_new_tokens = options.max_new_tokens;
    chosen.temperature = options.temperature;
    chosen.top_p = options.top_p;
    chosen.top_k = options.top_k;
    if (covers(options, offsetof(kataglyphis_text_options, json_schema) + sizeof(options.json_schema))
        && options.json_schema != nullptr) {
        chosen.json_schema = options.json_schema;
    }
    return seed_of(options, chosen) && stop_of(options, chosen);
}

}// namespace

extern "C" KATAGLYPHIS_C_API auto kataglyphis_add(int lhs, int rhs) -> int { return lhs + rhs; }

extern "C" KATAGLYPHIS_C_API void kataglyphis_text_options_default(kataglyphis_text_options *options)
{
    if (options == nullptr) { return; }
    const text::GenerationOptions defaults;
    options->struct_size = sizeof(kataglyphis_text_options);
    options->max_new_tokens = defaults.max_new_tokens;
    options->temperature = defaults.temperature;
    options->top_p = defaults.top_p;
    options->top_k = defaults.top_k;
    options->seed = KATAGLYPHIS_TEXT_NO_SEED;
    options->json_schema = nullptr;
    options->stop = nullptr;
    options->stop_count = 0;
    options->token_ids = nullptr;
    options->token_id_capacity = 0;
}

extern "C" KATAGLYPHIS_C_API auto kataglyphis_text_generator_create(const char *model_dir,
  std::int32_t provider,
  kataglyphis_text_generator **out) -> int
{
    text::ExecutionProvider chosen{};
    if (out == nullptr || model_dir == nullptr || !provider_of(provider, chosen)) {
        return KATAGLYPHIS_TEXT_INVALID_ARGUMENT;
    }
    *out = nullptr;
    auto *handle = new (std::nothrow) Handle{};
    if (handle == nullptr) { return KATAGLYPHIS_TEXT_GENERATION_FAILED; }
    const auto loaded = handle->generator.initialize(model_dir, chosen);
    if (!loaded) {
        delete handle;
        return status_of(loaded.error());
    }
    *out = reinterpret_cast<kataglyphis_text_generator *>(handle);
    return KATAGLYPHIS_TEXT_OK;
}

extern "C" KATAGLYPHIS_C_API auto kataglyphis_text_generator_generate(kataglyphis_text_generator *generator,
  const kataglyphis_text_message *messages,
  std::size_t message_count,
  const kataglyphis_text_options *options,
  kataglyphis_text_callback on_text,
  void *user_data,
  kataglyphis_text_stats *stats) -> int
{
    if (generator == nullptr || messages == nullptr || options == nullptr) { return KATAGLYPHIS_TEXT_INVALID_ARGUMENT; }
    std::vector<text::ChatMessage> chat;
    chat.reserve(message_count);
    for (std::size_t i = 0; i < message_count; ++i) {
        if (messages[i].role == nullptr || messages[i].content == nullptr) { return KATAGLYPHIS_TEXT_INVALID_ARGUMENT; }
        chat.push_back({ .role = messages[i].role, .content = messages[i].content });
    }
    text::GenerationOptions chosen;
    if (!options_of(*options, chosen)) { return KATAGLYPHIS_TEXT_INVALID_ARGUMENT; }
    text::TextCallback forward;
    if (on_text != nullptr) {
        forward = [on_text, user_data](
                    std::string_view piece) -> void { on_text(piece.data(), piece.size(), user_data); };
    }
    const auto result = handle_of(generator)->generator.generate(chat, chosen, forward);
    if (!result) { return status_of(result.error()); }
    if (stats != nullptr) {
        stats->finish_reason = finish_of(result->finish_reason);
        stats->prompt_tokens = result->prompt_tokens;
        stats->completion_tokens = result->tokens.size();
        stats->time_to_first_token_ms = result->time_to_first_token_ms;
        stats->decode_tokens_per_second = result->decode_tokens_per_second;
    }
    const auto ids = token_ids_of(*options);
    std::ranges::copy(result->tokens | std::views::take(ids.size()), ids.begin());
    return KATAGLYPHIS_TEXT_OK;
}

extern "C" KATAGLYPHIS_C_API void kataglyphis_text_generator_cancel(kataglyphis_text_generator *generator)
{
    if (generator != nullptr) { handle_of(generator)->generator.request_cancel(); }
}

extern "C" KATAGLYPHIS_C_API void kataglyphis_text_generator_destroy(kataglyphis_text_generator *generator)
{ delete handle_of(generator); }

extern "C" KATAGLYPHIS_C_API auto kataglyphis_text_status_message(int status) -> const char *
{
    if (status == KATAGLYPHIS_TEXT_OK) { return "success"; }
    if (status < KATAGLYPHIS_TEXT_LIBRARY_UNAVAILABLE || status > KATAGLYPHIS_TEXT_JSON_SCHEMA_UNSUPPORTED) {
        return "unknown status";
    }
    return text::to_string(static_cast<text::TextGenError>(status - 1)).data();
}
