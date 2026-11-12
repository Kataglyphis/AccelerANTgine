#pragma once

// A plugin execution provider is a module ONNX Runtime loads on registration; GetAvailableProviders never lists one.

#include <algorithm>
#include <array>
#include <filesystem>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

namespace kataglyphis::inference::ort_plugin {

// name: registered under it, and what its devices, the session and the profile then report.
struct Plugin
{
    const char *name;
    const char *root_variable;
    const char *module_file;
};

// One row per plugin provider; another plugin is one more row.
template<typename Provider>
inline constexpr std::array table{
    std::pair{ Provider::MigraphX, Plugin{ "MIGraphX", "ORT_AMDGPU_EP_ROOT", "libmigraphx-ep.so" } },
};

template<typename Provider> constexpr auto plugin_for(Provider provider) -> const Plugin *
{
    for (const auto &row : table<Provider>) {
        if (row.first == provider) { return &row.second; }
    }
    return nullptr;
}

// The image sets the root variable to nothing where it ships no module, and a package carries the module beside ORT.
inline auto module_candidates(const Plugin &plugin, std::string_view root, const std::filesystem::path &ort_directory)
  -> std::vector<std::filesystem::path>
{
    std::vector<std::filesystem::path> candidates;
    if (!root.empty()) { candidates.push_back(std::filesystem::path(root) / "lib" / plugin.module_file); }
    if (!ort_directory.empty()) { candidates.push_back(ort_directory / plugin.module_file); }
    return candidates;
}

// The first candidate that is a file; empty when none is.
inline auto first_file(const std::vector<std::filesystem::path> &candidates) -> std::filesystem::path
{
    for (const auto &candidate : candidates) {
        std::error_code ignored;
        if (std::filesystem::is_regular_file(candidate, ignored)) { return candidate; }
    }
    return {};
}

// A caller who named this provider reads here what was looked for and by which rule.
inline auto missing_module_reason(const Plugin &plugin,
  std::string_view root,
  const std::vector<std::filesystem::path> &candidates) -> std::string
{
    std::string reason = std::string(plugin.name) + " is not available: no " + plugin.module_file + " at";
    if (candidates.empty()) { reason += " any path"; }
    for (std::size_t i = 0; i < candidates.size(); ++i) { reason += (i == 0 ? " " : " or ") + candidates[i].string(); }
    reason += std::string(". It is looked for in $") + plugin.root_variable + "/lib when that variable is not empty (";
    reason += root.empty() ? std::string("it is empty") : "it is " + std::string(root);
    return reason + "), then beside the loaded ONNX Runtime library. The cpu device runs on the CPU";
}

// The plugin fails on an option it does not list, so this is the whole set.
inline auto device_options(int device_id) -> std::vector<std::pair<std::string, std::string>>
{ return { { "device_id", std::to_string(device_id) } }; }

// What this process registered: ONNX Runtime refuses a second registration of a name. The caller holds the lock.
class Registered
{
  public:
    // False only when `add` ran now and failed; ONNX Runtime rolls a failure back, so it is not remembered.
    template<typename Add> auto ensure(std::string_view name, Add &&add) -> bool
    {
        if (std::ranges::find(names_, name) != names_.end()) { return true; }
        if (!std::forward<Add>(add)()) { return false; }
        names_.emplace_back(name);
        return true;
    }

  private:
    std::vector<std::string> names_;
};

}// namespace kataglyphis::inference::ort_plugin
