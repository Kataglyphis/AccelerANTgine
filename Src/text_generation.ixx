module;

#include "kataglyphis_export.h"
#include <cstddef>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

export module kataglyphis.text_generation;

export namespace kataglyphis::text {

enum class TextGenError {
    LibraryUnavailable,
    ModelLoadFailed,
    ProviderUnavailable,
    TokenizerFailed,
    ChatTemplateFailed,
    EncodeFailed,
    InvalidOptions,
    GenerationFailed,
    NotInitialized,
    JsonSchemaUnsupported,
};

enum class ExecutionProvider { Cpu, Cuda, DirectML };

enum class FinishReason { Stop, Length, Cancelled };

struct ChatMessage
{
    std::string role;
    std::string content;
};

struct GenerationOptions
{
    int max_new_tokens = 128;
    double temperature = 0.0;
    double top_p = 1.0;
    int top_k = 50;
    /// Unset lets GenAI draw one; a set seed repeats the sampled tokens, and a negative one is invalid.
    std::optional<std::int32_t> seed;
    /// Empty leaves the output free; otherwise GenAI's llguidance holds it to this JSON schema.
    std::string json_schema;
    /// Generation ends before the first of these strings, which the text and on_text never contain.
    std::vector<std::string> stop;
};

struct GenerationResult
{
    std::string text;
    std::vector<std::int32_t> tokens;
    FinishReason finish_reason{ FinishReason::Stop };
    std::size_t prompt_tokens{};
    double time_to_first_token_ms{};
    double decode_tokens_per_second{};
};

/// Receives each decoded piece of text as it is generated, on the generating thread.
using TextCallback = std::function<void(std::string_view)>;

/// ONNX Runtime GenAI, loaded at run time from the chain build; see docs/source/text_generation.rst.
class KATAGLYPHIS_CPP_API TextGenerator
{
  public:
    TextGenerator();
    ~TextGenerator();

    TextGenerator(const TextGenerator &) = delete;
    auto operator=(const TextGenerator &) -> TextGenerator & = delete;
    TextGenerator(TextGenerator && /*other*/) noexcept;
    auto operator=(TextGenerator && /*other*/) noexcept -> TextGenerator &;

    [[nodiscard]] auto initialize(const std::filesystem::path &model_dir,
      ExecutionProvider provider = ExecutionProvider::Cpu) -> std::expected<void, TextGenError>;

    [[nodiscard]] auto is_initialized() const -> bool;

    /// Temperature 0 decodes greedily; on_text must not call back into this generator.
    [[nodiscard]] auto generate(const std::vector<ChatMessage> &messages,
      const GenerationOptions &options,
      const TextCallback &on_text = {}) -> std::expected<GenerationResult, TextGenError>;

    /// Safe from any thread; a running generate() ends after its current token with FinishReason::Cancelled.
    void request_cancel() noexcept;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] KATAGLYPHIS_CPP_API auto to_string(TextGenError error) noexcept -> std::string_view;

}// namespace kataglyphis::text
