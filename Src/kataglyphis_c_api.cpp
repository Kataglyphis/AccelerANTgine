module;

#if defined(_WIN32) || defined(_WIN64)
#ifdef KATAGLYPHIS_EXPORTS
#define KATAGLYPHIS_C_API __declspec(dllexport)
#else
#define KATAGLYPHIS_C_API __declspec(dllimport)
#endif
#else
#define KATAGLYPHIS_C_API __attribute__((visibility("default")))
#endif

module kataglyphis.c_api;

extern "C" KATAGLYPHIS_C_API auto kataglyphis_add(int lhs, int rhs) -> int { return lhs + rhs; }
