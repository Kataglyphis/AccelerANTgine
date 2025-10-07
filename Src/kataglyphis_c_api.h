// kataglyphis_c_api.h
#ifndef KATAGLYPHIS_C_API_H
#define KATAGLYPHIS_C_API_H

#ifdef __cplusplus
extern "C" {
#endif

// Platform-specific export declarations
#if defined(_WIN32) || defined(_WIN64)
    #ifdef KATAGLYPHIS_EXPORTS
        #define KATAGLYPHIS_API __declspec(dllexport)
    #else
        #define KATAGLYPHIS_API __declspec(dllimport)
    #endif
#else
    #define KATAGLYPHIS_API __attribute__((visibility("default")))
#endif

// Simple add function
KATAGLYPHIS_API int kataglyphis_add(int a, int b);

#ifdef __cplusplus
}
#endif

#endif // KATAGLYPHIS_C_API_H
