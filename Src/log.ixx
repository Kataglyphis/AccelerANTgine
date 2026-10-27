module;

#include "kataglyphis_export.h"
#include <cstdint>
#include <format>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

export module kataglyphis.log;

export namespace kataglyphis::log {

enum class Level : std::uint8_t { Debug = 0, Info = 1, Warning = 2, Error = 3, Off = 4 };

using Sink = std::function<void(Level, std::string_view)>;

/// Warning in release (NDEBUG) builds, Debug otherwise.
[[nodiscard]] KATAGLYPHIS_CPP_API auto build_default_level() noexcept -> Level;

/// Parses debug, info, warning, error or off, case-insensitively.
[[nodiscard]] KATAGLYPHIS_CPP_API auto parse_level(std::string_view text) noexcept -> std::optional<Level>;

/// The level an unset or unparsable ACCELERANTGINE_LOG_LEVEL value resolves to.
[[nodiscard]] KATAGLYPHIS_CPP_API auto level_from_environment(std::optional<std::string_view> value) noexcept
  -> Level;

[[nodiscard]] KATAGLYPHIS_CPP_API auto level() noexcept -> Level;
KATAGLYPHIS_CPP_API void set_level(Level threshold) noexcept;
[[nodiscard]] KATAGLYPHIS_CPP_API auto enabled(Level message_level) noexcept -> bool;

/// An empty sink restores the default stderr writer.
KATAGLYPHIS_CPP_API void set_sink(Sink sink);
KATAGLYPHIS_CPP_API void write(Level message_level, std::string_view message);

template<typename... Args> void debug(std::format_string<Args...> format, Args &&...args)
{
    if (enabled(Level::Debug)) { write(Level::Debug, std::format(format, std::forward<Args>(args)...)); }
}

template<typename... Args> void info(std::format_string<Args...> format, Args &&...args)
{
    if (enabled(Level::Info)) { write(Level::Info, std::format(format, std::forward<Args>(args)...)); }
}

template<typename... Args> void warning(std::format_string<Args...> format, Args &&...args)
{
    if (enabled(Level::Warning)) { write(Level::Warning, std::format(format, std::forward<Args>(args)...)); }
}

template<typename... Args> void error(std::format_string<Args...> format, Args &&...args)
{
    if (enabled(Level::Error)) { write(Level::Error, std::format(format, std::forward<Args>(args)...)); }
}

}// namespace kataglyphis::log
