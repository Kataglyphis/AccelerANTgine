module;

#if defined(_WIN32) || defined(_WIN64)
#  ifdef KATAGLYPHIS_EXPORTS
#    define KATAGLYPHIS_C_API __declspec(dllexport)
#  else
#    define KATAGLYPHIS_C_API __declspec(dllimport)
#  endif
#else
#  define KATAGLYPHIS_C_API __attribute__((visibility("default")))
#endif

export module kataglyphis.c_api;

export extern "C" KATAGLYPHIS_C_API int kataglyphis_add(int a, int b);