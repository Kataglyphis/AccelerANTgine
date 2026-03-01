module;
#include <string>

#if defined(_WIN32) || defined(_WIN64)
#  ifdef KATAGLYPHIS_EXPORTS
#    define KATAGLYPHIS_CPP_API __declspec(dllexport)
#  else
#    define KATAGLYPHIS_CPP_API __declspec(dllimport)
#  endif
#else
#  define KATAGLYPHIS_CPP_API __attribute__((visibility("default")))
#endif

export module kataglyphis.inference;

export namespace mylib {

class KATAGLYPHIS_CPP_API MyCalculator {
public:
	MyCalculator() = default;
	[[nodiscard]] auto add(int lhs, int rhs) const -> int;
	[[nodiscard]] auto version() const -> std::string;
};

}