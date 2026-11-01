/* Compiled as C17: the contract case through the embedder header alone, as a C host would run it. */
#include "kataglyphis_c_api.h"

#include <string.h>

typedef struct kataglyphis_text_contract_reply_s
{
    char *text;
    size_t size;
    size_t used;
} kataglyphis_text_contract_reply;

static void kataglyphis_text_contract_append(const char *piece, size_t length, void *user_data)
{
    kataglyphis_text_contract_reply *reply = (kataglyphis_text_contract_reply *)user_data;
    size_t room = reply->size - 1 - reply->used;
    size_t copied = length < room ? length : room;
    memcpy(reply->text + reply->used, piece, copied);
    reply->used += copied;
    reply->text[reply->used] = '\0';
}

int kataglyphis_text_contract_c(const char *model_dir,
  const kataglyphis_text_message *message,
  int32_t max_new_tokens,
  int32_t *ids,
  size_t id_capacity,
  char *text,
  size_t text_size,
  kataglyphis_text_stats *stats);

int kataglyphis_text_contract_c(const char *model_dir,
  const kataglyphis_text_message *message,
  int32_t max_new_tokens,
  int32_t *ids,
  size_t id_capacity,
  char *text,
  size_t text_size,
  kataglyphis_text_stats *stats)
{
    kataglyphis_text_generator *generator = NULL;
    kataglyphis_text_options options;
    kataglyphis_text_contract_reply reply = { text, text_size, 0 };
    int status = kataglyphis_text_generator_create(model_dir, KATAGLYPHIS_TEXT_PROVIDER_CPU, &generator);
    if (status != KATAGLYPHIS_TEXT_OK) { return status; }
    kataglyphis_text_options_default(&options);
    options.max_new_tokens = max_new_tokens;
    options.token_ids = ids;
    options.token_id_capacity = id_capacity;
    /* Greedy decoding ignores it; a mutant that samples instead then fails the same way on every run. */
    options.seed = 1;
    text[0] = '\0';
    status = kataglyphis_text_generator_generate(
      generator, message, 1, &options, kataglyphis_text_contract_append, &reply, stats);
    kataglyphis_text_generator_destroy(generator);
    return status;
}
