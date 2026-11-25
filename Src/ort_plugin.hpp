#pragma once

// Maps a provider to its row in the hub's exact ort_plugin_eps.hpp, which owns path and registration policy.

#include <array>
#include <utility>

#include "ort_plugin_eps.hpp"

namespace kataglyphis::inference::ort_plugin {

using Plugin = antfrastructure::ort_plugins::PluginLibrary;

// One row per plugin provider; another plugin is one more row.
template<typename Provider>
inline constexpr std::array table{
    std::pair{ Provider::MigraphX, antfrastructure::ort_plugins::migraphx },
};

template<typename Provider> constexpr auto plugin_for(Provider provider) -> const Plugin *
{
    for (const auto &row : table<Provider>) {
        if (row.first == provider) { return &row.second; }
    }
    return nullptr;
}

}// namespace kataglyphis::inference::ort_plugin
