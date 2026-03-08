#ifndef KATAGLYPHIS_C_API_H
#define KATAGLYPHIS_C_API_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(_WIN64)
#ifdef KATAGLYPHIS_EXPORTS
#define KATAGLYPHIS_C_API __declspec(dllexport)
#else
#define KATAGLYPHIS_C_API __declspec(dllimport)
#endif
#else
#define KATAGLYPHIS_C_API __attribute__((visibility("default")))
#endif

KATAGLYPHIS_C_API int kataglyphis_add(int lhs, int rhs);

#ifdef __cplusplus
}
#endif

#endif // KATAGLYPHIS_C_API_H
