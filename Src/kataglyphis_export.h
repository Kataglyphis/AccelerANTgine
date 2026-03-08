#ifndef KATAGLYPHIS_EXPORT_H
#define KATAGLYPHIS_EXPORT_H

#if defined(_WIN32) || defined(_WIN64)
#ifdef KATAGLYPHIS_EXPORTS
#define KATAGLYPHIS_C_API __declspec(dllexport)
#define KATAGLYPHIS_CPP_API __declspec(dllexport)
#else
#define KATAGLYPHIS_C_API __declspec(dllimport)
#define KATAGLYPHIS_CPP_API __declspec(dllimport)
#endif
#else
#define KATAGLYPHIS_C_API __attribute__((visibility("default")))
#define KATAGLYPHIS_CPP_API __attribute__((visibility("default")))
#endif

#endif// KATAGLYPHIS_EXPORT_H
