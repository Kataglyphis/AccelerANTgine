#ifndef KATAGLYPHIS_C_API_H
#define KATAGLYPHIS_C_API_H

#include "kataglyphis_export.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

KATAGLYPHIS_C_API int kataglyphis_add(int lhs, int rhs);

/* Text generation on the chain's ONNX Runtime GenAI; docs/source/text_generation.rst is the contract. */

#define KATAGLYPHIS_TEXT_OK 0
#define KATAGLYPHIS_TEXT_LIBRARY_UNAVAILABLE 1
#define KATAGLYPHIS_TEXT_MODEL_LOAD_FAILED 2
#define KATAGLYPHIS_TEXT_PROVIDER_UNAVAILABLE 3
#define KATAGLYPHIS_TEXT_TOKENIZER_FAILED 4
#define KATAGLYPHIS_TEXT_CHAT_TEMPLATE_FAILED 5
#define KATAGLYPHIS_TEXT_ENCODE_FAILED 6
#define KATAGLYPHIS_TEXT_INVALID_ARGUMENT 7
#define KATAGLYPHIS_TEXT_GENERATION_FAILED 8
#define KATAGLYPHIS_TEXT_NOT_INITIALIZED 9

#define KATAGLYPHIS_TEXT_PROVIDER_CPU 0
#define KATAGLYPHIS_TEXT_PROVIDER_CUDA 1
#define KATAGLYPHIS_TEXT_PROVIDER_DIRECTML 2

#define KATAGLYPHIS_TEXT_FINISH_STOP 0
#define KATAGLYPHIS_TEXT_FINISH_LENGTH 1
#define KATAGLYPHIS_TEXT_FINISH_CANCELLED 2

typedef struct kataglyphis_text_generator kataglyphis_text_generator;

typedef struct kataglyphis_text_message_s
{
    const char *role;
    const char *content;
} kataglyphis_text_message;

typedef struct kataglyphis_text_options_s
{
    int32_t max_new_tokens;
    double temperature;
    double top_p;
    int32_t top_k;
} kataglyphis_text_options;

typedef struct kataglyphis_text_stats_s
{
    int32_t finish_reason;
    size_t prompt_tokens;
    size_t completion_tokens;
    double time_to_first_token_ms;
    double decode_tokens_per_second;
} kataglyphis_text_stats;

/** Each decoded piece, valid only during the call; it must not call back into the generator. */
typedef void (*kataglyphis_text_callback)(const char *piece, size_t length, void *user_data);

/** The C++ defaults: 128 new tokens, greedy decoding. */
KATAGLYPHIS_C_API void kataglyphis_text_options_default(kataglyphis_text_options *options);

KATAGLYPHIS_C_API int
  kataglyphis_text_generator_create(const char *model_dir, int32_t provider, kataglyphis_text_generator **out);

/** on_text may be NULL; stats may be NULL. */
KATAGLYPHIS_C_API int kataglyphis_text_generator_generate(kataglyphis_text_generator *generator,
  const kataglyphis_text_message *messages,
  size_t message_count,
  const kataglyphis_text_options *options,
  kataglyphis_text_callback on_text,
  void *user_data,
  kataglyphis_text_stats *stats);

/** Safe from any thread; a running generate returns after its current token. */
KATAGLYPHIS_C_API void kataglyphis_text_generator_cancel(kataglyphis_text_generator *generator);

KATAGLYPHIS_C_API void kataglyphis_text_generator_destroy(kataglyphis_text_generator *generator);

/** A static English sentence for every status, including unknown ones. */
KATAGLYPHIS_C_API const char *kataglyphis_text_status_message(int status);

#ifdef __cplusplus
}
#endif

#endif// KATAGLYPHIS_C_API_H
