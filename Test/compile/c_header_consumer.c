/* Compiled as C17: the embedder header must stay valid C, which no C++ translation unit can prove. */
#include "kataglyphis_c_api.h"

/* A C compiler must lay the public structs out as api_contract_test.cpp pins them for C++. */
_Static_assert(sizeof(void *) == 8, "every lane builds the 64-bit ABI these offsets describe");
_Static_assert(sizeof(kataglyphis_text_message) == 16, "message size");
_Static_assert(offsetof(kataglyphis_text_message, role) == 0, "role");
_Static_assert(offsetof(kataglyphis_text_message, content) == 8, "content");
_Static_assert(sizeof(kataglyphis_text_options) == 88, "options size");
_Static_assert(offsetof(kataglyphis_text_options, struct_size) == 0, "struct_size");
_Static_assert(offsetof(kataglyphis_text_options, max_new_tokens) == 8, "max_new_tokens");
_Static_assert(offsetof(kataglyphis_text_options, temperature) == 16, "temperature");
_Static_assert(offsetof(kataglyphis_text_options, top_p) == 24, "top_p");
_Static_assert(offsetof(kataglyphis_text_options, top_k) == 32, "top_k");
_Static_assert(offsetof(kataglyphis_text_options, seed) == 40, "seed");
_Static_assert(offsetof(kataglyphis_text_options, json_schema) == 48, "json_schema");
_Static_assert(offsetof(kataglyphis_text_options, stop) == 56, "stop");
_Static_assert(offsetof(kataglyphis_text_options, stop_count) == 64, "stop_count");
_Static_assert(offsetof(kataglyphis_text_options, token_ids) == 72, "token_ids");
_Static_assert(offsetof(kataglyphis_text_options, token_id_capacity) == 80, "token_id_capacity");
_Static_assert(KATAGLYPHIS_TEXT_OPTIONS_V1_SIZE == 40, "version 1 size");
_Static_assert(sizeof(kataglyphis_text_stats) == 40, "stats size");
_Static_assert(offsetof(kataglyphis_text_stats, finish_reason) == 0, "finish_reason");
_Static_assert(offsetof(kataglyphis_text_stats, prompt_tokens) == 8, "prompt_tokens");
_Static_assert(offsetof(kataglyphis_text_stats, completion_tokens) == 16, "completion_tokens");
_Static_assert(offsetof(kataglyphis_text_stats, time_to_first_token_ms) == 24, "time_to_first_token_ms");
_Static_assert(offsetof(kataglyphis_text_stats, decode_tokens_per_second) == 32, "decode_tokens_per_second");

int kataglyphis_c_header_consumer_add(int lhs, int rhs);

int kataglyphis_c_header_consumer_add(int lhs, int rhs) { return kataglyphis_add(lhs, rhs); }

static void kataglyphis_c_header_consumer_count(const char *piece, size_t length, void *user_data)
{
    (void)piece;
    *(size_t *)user_data += length;
}

int kataglyphis_c_header_consumer_generate(const char *model_dir, size_t *bytes, kataglyphis_text_stats *stats);

int kataglyphis_c_header_consumer_generate(const char *model_dir, size_t *bytes, kataglyphis_text_stats *stats)
{
    kataglyphis_text_generator *generator = NULL;
    kataglyphis_text_options options;
    const kataglyphis_text_message message = { "user", "abc" };
    int status = kataglyphis_text_generator_create(model_dir, KATAGLYPHIS_TEXT_PROVIDER_CPU, &generator);
    if (status != KATAGLYPHIS_TEXT_OK) { return status; }
    kataglyphis_text_options_default(&options);
    options.max_new_tokens = 4;
    *bytes = 0;
    status = kataglyphis_text_generator_generate(
      generator, &message, 1, &options, kataglyphis_c_header_consumer_count, bytes, stats);
    kataglyphis_text_generator_destroy(generator);
    return status;
}
