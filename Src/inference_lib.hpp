#pragma once


#include <string>


namespace mylib {


class MyCalculator {
public:
  MyCalculator() = default;
  int add(int a, int b) const;
  std::string version() const;
};


} // namespace mylib
