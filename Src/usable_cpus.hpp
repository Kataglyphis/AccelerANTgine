#pragma once

// The CPUs a thread rule counts (hub CON304): third_party/ANTfrastructure/shared/contracts/usable-cpus.json

#include <algorithm>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace kataglyphis::inference::usable_cpus {

// The whole number `text` spells and nothing else, or nullopt.
inline auto parse_count(std::string_view text) -> std::optional<std::int64_t>
{
    std::int64_t value = 0;
    const auto read = std::from_chars(text.data(), text.data() + text.size(), value);
    if (read.ec != std::errc{} || read.ptr != text.data() + text.size()) { return std::nullopt; }
    return value;
}

// Whole CPUs of a `<quota> <period>` cpu.max text, rounded down; `max`, a malformed text and a zero period set none.
inline auto quota_cpus(std::string_view cpu_max) -> std::optional<std::int64_t>
{
    while (!cpu_max.empty() && (cpu_max.back() == '\n' || cpu_max.back() == ' ')) { cpu_max.remove_suffix(1); }
    const auto space = cpu_max.find(' ');
    if (space == std::string_view::npos) { return std::nullopt; }
    const auto quota = parse_count(cpu_max.substr(0, space));
    const auto period = parse_count(cpu_max.substr(space + 1));
    if (!quota || !period || *quota < 0 || *period <= 0) { return std::nullopt; }
    return *quota / *period;
}

// max(1, min(affinity, each quota in whole CPUs)): the floor of the smallest share is the smallest floor.
inline auto usable_of(int affinity, const std::vector<std::optional<std::string>> &cpu_max) -> int
{
    std::int64_t usable = affinity;
    for (const auto &text : cpu_max) {
        if (!text) { continue; }
        if (const auto cpus = quota_cpus(*text)) { usable = std::min(usable, *cpus); }
    }
    return static_cast<int>(std::max<std::int64_t>(usable, 1));
}

// Each cpu.max from the process's cgroup v2 up to the root, own first, nullopt where a level has none.
inline auto cgroup_cpu_max(const std::filesystem::path &root = "/sys/fs/cgroup",
  const std::filesystem::path &proc_cgroup = "/proc/self/cgroup") -> std::vector<std::optional<std::string>>
{
    std::ifstream membership(proc_cgroup);
    std::string line;
    std::optional<std::string> path;
    while (std::getline(membership, line)) {
        if (line.starts_with("0::")) {
            path = line.substr(3);
            break;
        }
    }
    if (!path) { return {}; }
    std::vector<std::string> parts;
    for (std::size_t start = 0; start <= path->size();) {
        const auto end = std::min(path->find('/', start), path->size());
        if (end > start) { parts.push_back(path->substr(start, end - start)); }
        start = end + 1;
    }
    // A cgroup outside this namespace shows as ../..; only the namespace's root is visible then.
    if (std::ranges::find(parts, "..") != parts.end()) { parts.clear(); }
    std::vector<std::optional<std::string>> found;
    for (auto depth = parts.size() + 1; depth-- > 0;) {
        auto dir = root;
        for (std::size_t level = 0; level < depth; ++level) { dir /= parts[level]; }
        std::ifstream file(dir / "cpu.max");
        std::string text;
        if (file && std::getline(file, text)) {
            found.emplace_back(text);
        } else {
            found.emplace_back(std::nullopt);
        }
    }
    return found;
}

}// namespace kataglyphis::inference::usable_cpus
