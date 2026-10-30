/* Compiled as C17: the embedder header must stay valid C, which no C++ translation unit can prove. */
#include "kataglyphis_c_api.h"

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
