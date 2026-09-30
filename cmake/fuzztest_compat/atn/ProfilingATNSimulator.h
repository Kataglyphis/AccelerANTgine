// ANTLR's ProfilingATNSimulator.cpp uses std::chrono without including <chrono>, which clang-cl rejects.

#pragma once

#include <chrono>

#include_next <atn/ProfilingATNSimulator.h>
