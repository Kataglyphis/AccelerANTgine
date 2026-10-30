module;

#include "kataglyphis_export.h"
#include <ort_genai_c.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

module kataglyphis.text_generation;

import kataglyphis.log;
import nlohmann.json;

namespace kataglyphis::text {

namespace {

    using Clock = std::chrono::steady_clock;

    struct GenaiApi
    {
        decltype(&OgaResultGetError) ResultGetError;
        decltype(&OgaDestroyResult) DestroyResult;
        decltype(&OgaCreateConfig) CreateConfig;
        decltype(&OgaConfigClearProviders) ConfigClearProviders;
        decltype(&OgaConfigAppendProvider) ConfigAppendProvider;
        decltype(&OgaDestroyConfig) DestroyConfig;
        decltype(&OgaCreateModelFromConfig) CreateModelFromConfig;
        decltype(&OgaDestroyModel) DestroyModel;
        decltype(&OgaCreateTokenizer) CreateTokenizer;
        decltype(&OgaDestroyTokenizer) DestroyTokenizer;
        decltype(&OgaTokenizerGetEosTokenIds) TokenizerGetEosTokenIds;
        decltype(&OgaTokenizerApplyChatTemplate) TokenizerApplyChatTemplate;
        decltype(&OgaDestroyString) DestroyString;
        decltype(&OgaCreateSequences) CreateSequences;
        decltype(&OgaDestroySequences) DestroySequences;
        decltype(&OgaTokenizerEncode) TokenizerEncode;
        decltype(&OgaSequencesGetSequenceCount) SequencesGetSequenceCount;
        decltype(&OgaCreateTokenizerStream) CreateTokenizerStream;
        decltype(&OgaDestroyTokenizerStream) DestroyTokenizerStream;
        decltype(&OgaTokenizerStreamDecode) TokenizerStreamDecode;
        decltype(&OgaCreateGeneratorParams) CreateGeneratorParams;
        decltype(&OgaDestroyGeneratorParams) DestroyGeneratorParams;
        decltype(&OgaGeneratorParamsSetSearchNumber) GeneratorParamsSetSearchNumber;
        decltype(&OgaGeneratorParamsSetSearchBool) GeneratorParamsSetSearchBool;
        decltype(&OgaCreateGenerator) CreateGenerator;
        decltype(&OgaDestroyGenerator) DestroyGenerator;
        decltype(&OgaGenerator_AppendTokenSequences) GeneratorAppendTokenSequences;
        decltype(&OgaGenerator_IsDone) GeneratorIsDone;
        decltype(&OgaGenerator_GenerateNextToken) GeneratorGenerateNextToken;
        decltype(&OgaGenerator_GetNextTokens) GeneratorGetNextTokens;
    };

#ifdef _WIN32
    constexpr const char *kDefaultLibrary = "onnxruntime-genai.dll";
    auto open_library(const char *name) -> void * { return static_cast<void *>(LoadLibraryA(name)); }
    auto library_symbol(void *library, const char *name) -> void *
    { return reinterpret_cast<void *>(GetProcAddress(static_cast<HMODULE>(library), name)); }
#else
    constexpr const char *kDefaultLibrary = "libonnxruntime-genai.so";
    auto open_library(const char *name) -> void * { return dlopen(name, RTLD_NOW | RTLD_LOCAL); }
    auto library_symbol(void *library, const char *name) -> void * { return dlsym(library, name); }
#endif

    template<typename Fn> auto bind(void *library, const char *name, Fn &slot) -> bool
    {
        slot = reinterpret_cast<Fn>(library_symbol(library, name));
        if (slot == nullptr) { log::error("ONNX Runtime GenAI: {} is missing from the loaded library", name); }
        return slot != nullptr;
    }

    // The loader's search, as for the chain ORT: ld.so.conf on Linux, the image's PATH on Windows.
    auto load_api() -> const GenaiApi *
    {
        static const std::unique_ptr<GenaiApi> api = [] -> std::unique_ptr<GenaiApi> {
            void *library = open_library(kDefaultLibrary);
            if (library == nullptr) {
                log::error("ONNX Runtime GenAI: cannot load {}", kDefaultLibrary);
                return nullptr;
            }
            auto table = std::make_unique<GenaiApi>();
            const bool complete =
              bind(library, "OgaResultGetError", table->ResultGetError)
              && bind(library, "OgaDestroyResult", table->DestroyResult)
              && bind(library, "OgaCreateConfig", table->CreateConfig)
              && bind(library, "OgaConfigClearProviders", table->ConfigClearProviders)
              && bind(library, "OgaConfigAppendProvider", table->ConfigAppendProvider)
              && bind(library, "OgaDestroyConfig", table->DestroyConfig)
              && bind(library, "OgaCreateModelFromConfig", table->CreateModelFromConfig)
              && bind(library, "OgaDestroyModel", table->DestroyModel)
              && bind(library, "OgaCreateTokenizer", table->CreateTokenizer)
              && bind(library, "OgaDestroyTokenizer", table->DestroyTokenizer)
              && bind(library, "OgaTokenizerGetEosTokenIds", table->TokenizerGetEosTokenIds)
              && bind(library, "OgaTokenizerApplyChatTemplate", table->TokenizerApplyChatTemplate)
              && bind(library, "OgaDestroyString", table->DestroyString)
              && bind(library, "OgaCreateSequences", table->CreateSequences)
              && bind(library, "OgaDestroySequences", table->DestroySequences)
              && bind(library, "OgaTokenizerEncode", table->TokenizerEncode)
              && bind(library, "OgaSequencesGetSequenceCount", table->SequencesGetSequenceCount)
              && bind(library, "OgaCreateTokenizerStream", table->CreateTokenizerStream)
              && bind(library, "OgaDestroyTokenizerStream", table->DestroyTokenizerStream)
              && bind(library, "OgaTokenizerStreamDecode", table->TokenizerStreamDecode)
              && bind(library, "OgaCreateGeneratorParams", table->CreateGeneratorParams)
              && bind(library, "OgaDestroyGeneratorParams", table->DestroyGeneratorParams)
              && bind(library, "OgaGeneratorParamsSetSearchNumber", table->GeneratorParamsSetSearchNumber)
              && bind(library, "OgaGeneratorParamsSetSearchBool", table->GeneratorParamsSetSearchBool)
              && bind(library, "OgaCreateGenerator", table->CreateGenerator)
              && bind(library, "OgaDestroyGenerator", table->DestroyGenerator)
              && bind(library, "OgaGenerator_AppendTokenSequences", table->GeneratorAppendTokenSequences)
              && bind(library, "OgaGenerator_IsDone", table->GeneratorIsDone)
              && bind(library, "OgaGenerator_GenerateNextToken", table->GeneratorGenerateNextToken)
              && bind(library, "OgaGenerator_GetNextTokens", table->GeneratorGetNextTokens);
            return complete ? std::move(table) : nullptr;
        }();
        return api.get();
    }

    auto succeeded(const GenaiApi &api, OgaResult *result, std::string_view what) -> bool
    {
        if (result == nullptr) { return true; }
        log::error("ONNX Runtime GenAI: {}: {}", what, api.ResultGetError(result));
        api.DestroyResult(result);
        return false;
    }

    template<typename T, auto Destroy> struct Release
    {
        const GenaiApi *api = nullptr;
        void operator()(T *handle) const
        {
            if (handle != nullptr) { (api->*Destroy)(handle); }
        }
    };

    using Config = std::unique_ptr<OgaConfig, Release<OgaConfig, &GenaiApi::DestroyConfig>>;
    using Model = std::unique_ptr<OgaModel, Release<OgaModel, &GenaiApi::DestroyModel>>;
    using Tokenizer = std::unique_ptr<OgaTokenizer, Release<OgaTokenizer, &GenaiApi::DestroyTokenizer>>;
    using Sequences = std::unique_ptr<OgaSequences, Release<OgaSequences, &GenaiApi::DestroySequences>>;
    using Stream = std::unique_ptr<OgaTokenizerStream, Release<OgaTokenizerStream, &GenaiApi::DestroyTokenizerStream>>;
    using Params = std::unique_ptr<OgaGeneratorParams, Release<OgaGeneratorParams, &GenaiApi::DestroyGeneratorParams>>;
    using Generator = std::unique_ptr<OgaGenerator, Release<OgaGenerator, &GenaiApi::DestroyGenerator>>;

    auto provider_name(ExecutionProvider provider) -> const char *
    {
        switch (provider) {
        case ExecutionProvider::Cuda:
            return "cuda";
        case ExecutionProvider::DirectML:
            return "dml";
        case ExecutionProvider::Cpu:
            break;
        }
        return nullptr;
    }

    auto messages_json(const std::vector<ChatMessage> &messages) -> std::string
    {
        auto array = nlohmann::json::array();
        for (const auto &message : messages) {
            array.push_back({ { "role", message.role }, { "content", message.content } });
        }
        return array.dump();
    }

    auto milliseconds(Clock::duration duration) -> double
    { return std::chrono::duration<double, std::milli>(duration).count(); }

}// namespace

struct TextGenerator::Impl
{
    const GenaiApi *api = nullptr;
    Model model;
    Tokenizer tokenizer;
    std::vector<std::int32_t> eos_tokens;
    mutable std::shared_mutex mutex;
    std::atomic<bool> cancel{ false };

    auto prompt_tokens(const std::vector<ChatMessage> &messages) const -> std::expected<Sequences, TextGenError>;
    auto make_generator(const OgaSequences &prompt, std::size_t prompt_count, const GenerationOptions &options) const
      -> std::expected<Generator, TextGenError>;
    auto next_token(OgaGenerator *generator,
      OgaTokenizerStream *stream,
      const TextCallback &on_text,
      GenerationResult &result) const -> std::expected<void, TextGenError>;
    auto decode(OgaGenerator *generator, const TextCallback &on_text, GenerationResult &result) const
      -> std::expected<void, TextGenError>;
    void
      finish(GenerationResult &result, Clock::time_point start, Clock::time_point first, Clock::time_point end) const;
};

auto TextGenerator::Impl::prompt_tokens(const std::vector<ChatMessage> &messages) const
  -> std::expected<Sequences, TextGenError>
{
    const std::string chat = messages_json(messages);
    const char *prompt = nullptr;
    if (!succeeded(*api,
          api->TokenizerApplyChatTemplate(tokenizer.get(), nullptr, chat.c_str(), nullptr, true, &prompt),
          "chat template")) {
        return std::unexpected(TextGenError::ChatTemplateFailed);
    }
    const std::string text = prompt;
    api->DestroyString(prompt);
    OgaSequences *raw = nullptr;
    if (!succeeded(*api, api->CreateSequences(&raw), "sequences")) {
        return std::unexpected(TextGenError::EncodeFailed);
    }
    Sequences sequences{ raw, { api } };
    if (!succeeded(*api, api->TokenizerEncode(tokenizer.get(), text.c_str(), sequences.get()), "encode")) {
        return std::unexpected(TextGenError::EncodeFailed);
    }
    return sequences;
}

auto TextGenerator::Impl::make_generator(const OgaSequences &prompt,
  std::size_t prompt_count,
  const GenerationOptions &options) const -> std::expected<Generator, TextGenError>
{
    OgaGeneratorParams *raw_params = nullptr;
    if (!succeeded(*api, api->CreateGeneratorParams(model.get(), &raw_params), "generator params")) {
        return std::unexpected(TextGenError::GenerationFailed);
    }
    const Params params{ raw_params, { api } };
    const bool sample = options.temperature > 0.0;
    const double max_length = static_cast<double>(prompt_count) + options.max_new_tokens;
    bool configured =
      succeeded(*api, api->GeneratorParamsSetSearchNumber(params.get(), "max_length", max_length), "max_length")
      && succeeded(*api, api->GeneratorParamsSetSearchBool(params.get(), "do_sample", sample), "do_sample");
    if (configured && sample) {
        configured =
          succeeded(
            *api, api->GeneratorParamsSetSearchNumber(params.get(), "temperature", options.temperature), "temperature")
          && succeeded(*api, api->GeneratorParamsSetSearchNumber(params.get(), "top_p", options.top_p), "top_p")
          && succeeded(*api, api->GeneratorParamsSetSearchNumber(params.get(), "top_k", options.top_k), "top_k");
    }
    if (!configured) { return std::unexpected(TextGenError::InvalidOptions); }
    OgaGenerator *raw_generator = nullptr;
    if (!succeeded(*api, api->CreateGenerator(model.get(), params.get(), &raw_generator), "generator")) {
        return std::unexpected(TextGenError::GenerationFailed);
    }
    Generator generator{ raw_generator, { api } };
    if (!succeeded(*api, api->GeneratorAppendTokenSequences(generator.get(), &prompt), "prompt")) {
        return std::unexpected(TextGenError::GenerationFailed);
    }
    return generator;
}

auto TextGenerator::Impl::next_token(OgaGenerator *generator,
  OgaTokenizerStream *stream,
  const TextCallback &on_text,
  GenerationResult &result) const -> std::expected<void, TextGenError>
{
    const std::int32_t *next = nullptr;
    std::size_t count = 0;
    if (!succeeded(*api, api->GeneratorGenerateNextToken(generator), "next token")
        || !succeeded(*api, api->GeneratorGetNextTokens(generator, &next, &count), "next tokens") || count == 0) {
        return std::unexpected(TextGenError::GenerationFailed);
    }
    result.tokens.push_back(*next);
    const char *piece = nullptr;
    if (!succeeded(*api, api->TokenizerStreamDecode(stream, *next, &piece), "decode")) {
        return std::unexpected(TextGenError::TokenizerFailed);
    }
    // A piece that ends inside a UTF-8 character stays in the stream until it is complete.
    if (piece == nullptr || *piece == '\0') { return {}; }
    result.text += piece;
    if (on_text) { on_text(piece); }
    return {};
}

auto TextGenerator::Impl::decode(OgaGenerator *generator, const TextCallback &on_text, GenerationResult &result) const
  -> std::expected<void, TextGenError>
{
    OgaTokenizerStream *raw_stream = nullptr;
    if (!succeeded(*api, api->CreateTokenizerStream(tokenizer.get(), &raw_stream), "tokenizer stream")) {
        return std::unexpected(TextGenError::TokenizerFailed);
    }
    const Stream stream{ raw_stream, { api } };
    const auto start = Clock::now();
    auto first = start;
    while (!api->GeneratorIsDone(generator)) {
        if (cancel.load()) {
            result.finish_reason = FinishReason::Cancelled;
            break;
        }
        if (auto stepped = next_token(generator, stream.get(), on_text, result); !stepped) { return stepped; }
        if (result.tokens.size() == 1) { first = Clock::now(); }
    }
    finish(result, start, first, Clock::now());
    return {};
}

void TextGenerator::Impl::finish(GenerationResult &result,
  Clock::time_point start,
  Clock::time_point first,
  Clock::time_point end) const
{
    if (result.finish_reason != FinishReason::Cancelled) {
        const bool stopped = !result.tokens.empty() && std::ranges::contains(eos_tokens, result.tokens.back());
        result.finish_reason = stopped ? FinishReason::Stop : FinishReason::Length;
    }
    if (!result.tokens.empty()) { result.time_to_first_token_ms = milliseconds(first - start); }
    if (result.tokens.size() > 1 && end > first) {
        result.decode_tokens_per_second =
          static_cast<double>(result.tokens.size() - 1) / std::chrono::duration<double>(end - first).count();
    }
}

TextGenerator::TextGenerator() : impl_(std::make_unique<Impl>()) {}
TextGenerator::~TextGenerator() = default;
TextGenerator::TextGenerator(TextGenerator &&) noexcept = default;
auto TextGenerator::operator=(TextGenerator &&) noexcept -> TextGenerator & = default;

auto TextGenerator::initialize(const std::filesystem::path &model_dir, ExecutionProvider provider)
  -> std::expected<void, TextGenError>
{
    const std::unique_lock lock(impl_->mutex);
    const GenaiApi *api = load_api();
    if (api == nullptr) { return std::unexpected(TextGenError::LibraryUnavailable); }
    OgaConfig *raw_config = nullptr;
    if (!succeeded(*api, api->CreateConfig(model_dir.string().c_str(), &raw_config), "config")) {
        return std::unexpected(TextGenError::ModelLoadFailed);
    }
    const Config config{ raw_config, { api } };
    const char *name = provider_name(provider);
    if (!succeeded(*api, api->ConfigClearProviders(config.get()), "providers")
        || (name != nullptr && !succeeded(*api, api->ConfigAppendProvider(config.get(), name), name))) {
        return std::unexpected(TextGenError::ProviderUnavailable);
    }
    OgaModel *raw_model = nullptr;
    if (!succeeded(*api, api->CreateModelFromConfig(config.get(), &raw_model), "model")) {
        return std::unexpected(TextGenError::ModelLoadFailed);
    }
    Model model{ raw_model, { api } };
    OgaTokenizer *raw_tokenizer = nullptr;
    if (!succeeded(*api, api->CreateTokenizer(model.get(), &raw_tokenizer), "tokenizer")) {
        return std::unexpected(TextGenError::TokenizerFailed);
    }
    Tokenizer tokenizer{ raw_tokenizer, { api } };
    const std::int32_t *eos = nullptr;
    std::size_t eos_count = 0;
    if (!succeeded(*api, api->TokenizerGetEosTokenIds(tokenizer.get(), &eos, &eos_count), "eos tokens")) {
        return std::unexpected(TextGenError::TokenizerFailed);
    }
    const std::span<const std::int32_t> eos_ids(eos, eos_count);
    impl_->eos_tokens.assign(eos_ids.begin(), eos_ids.end());
    impl_->api = api;
    impl_->tokenizer = std::move(tokenizer);
    impl_->model = std::move(model);
    return {};
}

auto TextGenerator::is_initialized() const -> bool
{
    const std::shared_lock lock(impl_->mutex);
    return impl_->model != nullptr;
}

auto TextGenerator::generate(const std::vector<ChatMessage> &messages,
  const GenerationOptions &options,
  const TextCallback &on_text) -> std::expected<GenerationResult, TextGenError>
{
    const std::unique_lock lock(impl_->mutex);
    if (impl_->model == nullptr) { return std::unexpected(TextGenError::NotInitialized); }
    if (messages.empty() || options.max_new_tokens <= 0) { return std::unexpected(TextGenError::InvalidOptions); }
    impl_->cancel.store(false);
    auto prompt = impl_->prompt_tokens(messages);
    if (!prompt) { return std::unexpected(prompt.error()); }
    GenerationResult result;
    result.prompt_tokens = impl_->api->SequencesGetSequenceCount(prompt->get(), 0);
    auto generator = impl_->make_generator(**prompt, result.prompt_tokens, options);
    if (!generator) { return std::unexpected(generator.error()); }
    if (auto decoded = impl_->decode(generator->get(), on_text, result); !decoded) {
        return std::unexpected(decoded.error());
    }
    return result;
}

void TextGenerator::request_cancel() noexcept { impl_->cancel.store(true); }

auto to_string(TextGenError error) noexcept -> std::string_view
{
    switch (error) {
    case TextGenError::LibraryUnavailable:
        return "the ONNX Runtime GenAI library could not be loaded";
    case TextGenError::ModelLoadFailed:
        return "the model directory could not be loaded";
    case TextGenError::ProviderUnavailable:
        return "the execution provider is not available";
    case TextGenError::TokenizerFailed:
        return "the tokenizer failed";
    case TextGenError::ChatTemplateFailed:
        return "the chat template could not be applied";
    case TextGenError::EncodeFailed:
        return "the prompt could not be encoded";
    case TextGenError::InvalidOptions:
        return "the messages or options are invalid";
    case TextGenError::GenerationFailed:
        return "generation failed";
    case TextGenError::NotInitialized:
        return "the generator is not initialized";
    }
    return "unknown error";
}

}// namespace kataglyphis::text
