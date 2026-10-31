#pragma once

#include <optional>
#include <string_view>

#ifndef KATAGLYPHIS_DEMO_DEFAULT_DEVICE
#define KATAGLYPHIS_DEMO_DEFAULT_DEVICE "cpu"
#endif

namespace kataglyphis::demo {

inline constexpr std::string_view default_device = KATAGLYPHIS_DEMO_DEFAULT_DEVICE;

template<typename Provider> constexpr auto parse_device(std::string_view name) -> std::optional<Provider>
{
    if (name == "cpu") { return Provider::Cpu; }
    if (name == "cuda") { return Provider::Cuda; }
    if (name == "migraphx") { return Provider::MigraphX; }
    if (name == "directml") { return Provider::DirectML; }
    return std::nullopt;
}

}// namespace kataglyphis::demo
