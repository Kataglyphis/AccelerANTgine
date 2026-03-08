module;

#include "kataglyphis_export.h"

module kataglyphis.c_api;

extern "C" KATAGLYPHIS_C_API auto kataglyphis_add(int lhs, int rhs) -> int { return lhs + rhs; }
