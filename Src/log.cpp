module;

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

module kataglyphis.log;

namespace kataglyphis::log {

namespace {
    constexpr int kUnresolved = -1;
    constexpr const char *kEnvironmentVariable = "ACCELERANTGINE_LOG_LEVEL";

    std::atomic<int> g_level{ kUnresolved };
    std::mutex g_sink_mutex;
    Sink g_sink;

    auto level_name(Level message_level) noexcept -> std::string_view
    {
        switch (message_level) {
        case Level::Debug:
            return "debug";
        case Level::Info:
            return "info";
        case Level::Warning:
            return "warning";
        case Level::Error:
            return "error";
        case Level::Off:
            return "off";
        }
        return "unknown";
    }

    auto environment_value() -> std::optional<std::string>
    {
#if defined(_WIN32)
        char *buffer = nullptr;
        std::size_t length = 0;
        if (_dupenv_s(&buffer, &length, kEnvironmentVariable) != 0 || buffer == nullptr) { return std::nullopt; }
        std::string value(buffer);
        std::free(buffer);
        return value;
#else
        const char *value = std::getenv(kEnvironmentVariable);
        if (value == nullptr) { return std::nullopt; }
        return std::string(value);
#endif
    }
}// namespace

auto release_build() noexcept -> bool
{
#if defined(NDEBUG)
    return true;
#else
    return false;
#endif
}

auto build_default_level() noexcept -> Level { return release_build() ? Level::Warning : Level::Debug; }

auto parse_level(std::string_view text) noexcept -> std::optional<Level>
{
    static constexpr std::array<Level, 5> kLevels{
        Level::Debug, Level::Info, Level::Warning, Level::Error, Level::Off
    };
    for (const Level candidate : kLevels) {
        const std::string_view name = level_name(candidate);
        if (std::ranges::equal(text, name, [](char lhs, char rhs) -> bool {
                return std::tolower(static_cast<unsigned char>(lhs)) == static_cast<unsigned char>(rhs);
            })) {
            return candidate;
        }
    }
    return std::nullopt;
}

auto level_from_environment(std::optional<std::string_view> value) noexcept -> Level
{
    if (value) {
        if (auto parsed = parse_level(*value)) { return *parsed; }
    }
    return build_default_level();
}

auto level() noexcept -> Level
{
    int current = g_level.load(std::memory_order_acquire);
    if (current == kUnresolved) {
        const std::optional<std::string> value = environment_value();
        const int resolved = static_cast<int>(level_from_environment(value));
        // A concurrent set_level wins over the environment default.
        if (g_level.compare_exchange_strong(current, resolved, std::memory_order_acq_rel)) { current = resolved; }
    }
    return static_cast<Level>(current);
}

void set_level(Level threshold) noexcept { g_level.store(static_cast<int>(threshold), std::memory_order_release); }

auto enabled(Level message_level) noexcept -> bool
{ return message_level != Level::Off && static_cast<int>(message_level) >= static_cast<int>(level()); }

void set_sink(Sink sink)
{
    const std::scoped_lock lock(g_sink_mutex);
    g_sink = std::move(sink);
}

void write(Level message_level, std::string_view message)
{
    if (!enabled(message_level)) { return; }
    const std::scoped_lock lock(g_sink_mutex);
    if (g_sink) {
        g_sink(message_level, message);
        return;
    }
    const std::string_view name = level_name(message_level);
    std::fprintf(stderr,
      "[accelerantgine:%.*s] %.*s\n",
      static_cast<int>(name.size()),
      name.data(),
      static_cast<int>(message.size()),
      message.data());
}

}// namespace kataglyphis::log
