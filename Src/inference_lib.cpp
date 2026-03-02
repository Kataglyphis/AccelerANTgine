module;

#include <string>// NOLINT(misc-include-cleaner)

#if defined(_WIN32) || defined(_WIN64)
#ifdef KATAGLYPHIS_EXPORTS
#define KATAGLYPHIS_CPP_API __declspec(dllexport)
#else
#define KATAGLYPHIS_CPP_API __declspec(dllimport)
#endif
#else
#define KATAGLYPHIS_CPP_API __attribute__((visibility("default")))
#endif

module kataglyphis.inference;

namespace mylib {

KATAGLYPHIS_CPP_API auto MyCalculator::add(int lhs, int rhs) const -> int { return lhs + rhs; }

KATAGLYPHIS_CPP_API auto MyCalculator::version() const -> std::string { return "1.0.0"; }

}// namespace mylib
