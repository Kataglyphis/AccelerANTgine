/* Compiled as C17: the embedder header must stay valid C, which no C++ translation unit can prove. */
#include "kataglyphis_c_api.h"

int kataglyphis_c_header_consumer_add(int lhs, int rhs);

int kataglyphis_c_header_consumer_add(int lhs, int rhs) { return kataglyphis_add(lhs, rhs); }
