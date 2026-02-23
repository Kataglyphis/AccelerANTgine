#include "inference_lib.hpp"

#include <iostream>

int main() {
  mylib::MyCalculator calculator;
  std::cout << "KataglyphisCppInference " << calculator.version() << '\n';
  return 0;
}
