#pragma once


#ifdef __cplusplus
extern "C" {
#endif


#if defined(_WIN32) || defined(__CYGWIN__)
#ifdef MYLIB_EXPORTS
#ifdef __GNUC__
#define MYLIB_API __attribute__((dllexport))
#else
#define MYLIB_API __declspec(dllexport)
#endif
#else
#ifdef __GNUC__
#define MYLIB_API __attribute__((dllimport))
#else
#define MYLIB_API __declspec(dllimport)
#endif
#endif
#else
#if __GNUC__ >= 4
#define MYLIB_API __attribute__((visibility("default")))
#else
#define MYLIB_API
#endif
#endif


// Simple C API
MYLIB_API int mylib_add(int a, int b);
MYLIB_API const char* mylib_version();


#ifdef __cplusplus
}
#endif
