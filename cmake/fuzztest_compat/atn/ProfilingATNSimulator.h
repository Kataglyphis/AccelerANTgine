// ANTLR's ProfilingATNSimulator.cpp uses std::chrono types without including
// <chrono> directly. Provide that include from the project-owned compatibility
// overlay so clang-cl can compile the fetched runtime unmodified.

#pragma once

#include <chrono>

#include_next <atn/ProfilingATNSimulator.h>
