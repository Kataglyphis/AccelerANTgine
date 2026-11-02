export module kataglyphis.config_error;

export namespace kataglyphis::config {

enum class ConfigError { FileNotFound, ParseError, MissingField, InvalidValue };

}// namespace kataglyphis::config
