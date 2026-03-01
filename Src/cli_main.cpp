#include <iostream>

import kataglyphis.inference;

auto main() -> int
{
    mylib::MyCalculator calculator;
    std::cout << "KataglyphisCppInference " << calculator.version() << '\n';
    return 0;
}
