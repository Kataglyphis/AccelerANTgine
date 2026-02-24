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

module kataglyphis.inference;

namespace mylib {

KATAGLYPHIS_CPP_API int MyCalculator::add(int a, int b) const {
	return a + b;
}

KATAGLYPHIS_CPP_API std::string MyCalculator::version() const {
	return "1.0.0";
}

} // namespace mylib
