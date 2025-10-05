#include "c_api.h"
#include "inference_lib.hpp"


extern "C" {


MYLIB_API int mylib_add(int a, int b) {
mylib::MyCalculator calc;
return calc.add(a, b);
}


MYLIB_API const char* mylib_version() {
static std::string v = mylib::MyCalculator().version();
return v.c_str(); // safe: lives for program lifetime
}


} // extern "C"
