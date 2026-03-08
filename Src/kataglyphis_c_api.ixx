module;

#include "kataglyphis_export.h"

export module kataglyphis.c_api;

export extern "C" KATAGLYPHIS_C_API auto kataglyphis_add(int lhs, int rhs) -> int;