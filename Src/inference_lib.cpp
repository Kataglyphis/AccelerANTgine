module;

#include "kataglyphis_export.h"
#include <format>
#include <string>// NOLINT(misc-include-cleaner)

module kataglyphis.inference;
import kataglyphis.project_config;

namespace mylib {

KATAGLYPHIS_CPP_API auto MyCalculator::add(int lhs, int rhs) const -> int { return lhs + rhs; }

KATAGLYPHIS_CPP_API auto MyCalculator::version() const -> std::string
{
    return std::format(
      "{}.{}", kataglyphis::project_config::project_version_major, kataglyphis::project_config::project_version_minor);
}

}// namespace mylib
