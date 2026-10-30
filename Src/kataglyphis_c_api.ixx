module;

#include "kataglyphis_c_api.h"

export module kataglyphis.c_api;

// Re-exported from the header, so an importer and an includer see the same global-module entities.
/// \cond
export using ::kataglyphis_add;
export using ::kataglyphis_text_generator;
export using ::kataglyphis_text_message;
export using ::kataglyphis_text_options;
export using ::kataglyphis_text_stats;
export using ::kataglyphis_text_callback;
export using ::kataglyphis_text_options_default;
export using ::kataglyphis_text_generator_create;
export using ::kataglyphis_text_generator_generate;
export using ::kataglyphis_text_generator_cancel;
export using ::kataglyphis_text_generator_destroy;
export using ::kataglyphis_text_status_message;
/// \endcond
