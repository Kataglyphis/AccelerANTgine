module;

#include "kataglyphis_export.h"
#include <string>

export module kataglyphis.inference;

export namespace mylib {

class KATAGLYPHIS_CPP_API MyCalculator
{
  public:
    MyCalculator() = default;
    [[nodiscard]] auto add(int lhs, int rhs) const -> int;
    [[nodiscard]] auto version() const -> std::string;
};

}// namespace mylib