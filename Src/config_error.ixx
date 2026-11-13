module;

#include <string_view>

export module kataglyphis.config_error;

export namespace kataglyphis::config {

enum class ConfigError { FileNotFound, ParseError, MissingField, InvalidValue };

// The value's own name, for a log line, a message or a binding; no default, so a new value fails the build here.
[[nodiscard]] constexpr auto to_string(ConfigError error) noexcept -> std::string_view
{
    switch (error) {
    case ConfigError::FileNotFound:
        return "FileNotFound";
    case ConfigError::ParseError:
        return "ParseError";
    case ConfigError::MissingField:
        return "MissingField";
    case ConfigError::InvalidValue:
        return "InvalidValue";
    }
    return "UnknownError";
}

}// namespace kataglyphis::config
