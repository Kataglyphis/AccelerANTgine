#include "inference_lib.hpp"


namespace mylib {


int MyCalculator::add(int a, int b) const {
return a + b;
}


std::string MyCalculator::version() const {
return "1.0.0";
}


} // namespace mylib
