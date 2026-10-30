// A Linux package carries the image's own GStreamer and plugins; see AGENTS.md.
#if defined(__linux__)
#include "bundled_gstreamer.hpp"

#include <dlfcn.h>
#include <sys/stat.h>

#include <cstdlib>
#include <filesystem>
#include <functional>
#include <string>
#include <system_error>

namespace kataglyphis::bundled_gstreamer {

namespace {
    const char anchor = 0;
}

auto plugin_dir() -> std::string
{
    Dl_info info{};
    if (::dladdr(&anchor, &info) == 0 || info.dli_fname == nullptr) { return {}; }
    const std::string library = info.dli_fname;
    const std::size_t slash = library.find_last_of('/');
    if (slash == std::string::npos) { return {}; }
    // Beside the library when another package embeds it, under CPackOptions.cmake's PRIVATE_DIR in its own.
    for (const char *sub : { "/gstreamer-1.0", "/accelerantgine/gstreamer-1.0" }) {
        const std::string dir = library.substr(0, slash) + sub;
        struct stat status{};
        if (::stat(dir.c_str(), &status) != 0 || !S_ISDIR(status.st_mode)) { continue; }
        std::error_code error;
        const std::filesystem::path canonical = std::filesystem::canonical(dir, error);
        return error ? dir : canonical.string();
    }
    return {};
}

}// namespace kataglyphis::bundled_gstreamer

namespace {

void set_unless_set(const char *name, const std::string &value)
{
    if (::getenv(name) == nullptr) { ::setenv(name, value.c_str(), 1); }
}

auto registry_path(const std::string &plugins) -> std::string
{
    const char *cache = ::getenv("XDG_CACHE_HOME");
    const char *home = ::getenv("HOME");
    if ((cache == nullptr || *cache == '\0') && home == nullptr) { return {}; }
    const std::filesystem::path base =
      (cache != nullptr && *cache != '\0') ? std::filesystem::path(cache) : std::filesystem::path(home) / ".cache";
    // One registry per installed copy: a shared one is rescanned whenever another GStreamer used it last.
    const std::filesystem::path dir = base / "kataglyphis-gstreamer";
    std::error_code ignored;
    std::filesystem::create_directories(dir, ignored);
    return (dir / ("registry-" + std::to_string(std::hash<std::string>{}(plugins)) + ".bin")).string();
}

// Only the bundled plugins load: the distro's are built against another GStreamer, and the bundle ships no scanner.
__attribute__((constructor)) void use_bundled_gstreamer()
{
    const std::string plugins = kataglyphis::bundled_gstreamer::plugin_dir();
    if (plugins.empty()) { return; }
    set_unless_set("GST_PLUGIN_PATH", plugins);
    set_unless_set("GST_PLUGIN_SYSTEM_PATH", "");
    set_unless_set("GST_PLUGIN_SYSTEM_PATH_1_0", "");
    set_unless_set("GST_REGISTRY_FORK", "no");
    const std::string registry = registry_path(plugins);
    if (!registry.empty()) { set_unless_set("GST_REGISTRY", registry); }
}

}// namespace
#endif

#if defined(_WIN32)
#include "bundled_gstreamer.hpp"
#include <windows.h>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>
#include <gst/gst.h>
#include <mutex>

namespace kataglyphis::bundled_gstreamer {
namespace { const char anchor = 0; }

auto plugin_dir() -> std::string
{
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
          reinterpret_cast<LPCWSTR>(&anchor), &module)) { return {}; }
    std::vector<wchar_t> name(32768);
    const DWORD length = GetModuleFileNameW(module, name.data(), static_cast<DWORD>(name.size()));
    if (length == 0 || length >= name.size()) { return {}; }
    const auto base = std::filesystem::path(std::wstring(name.data(), length)).parent_path();
    for (const auto &candidate : { base / "gstreamer-1.0", base / "lib/gstreamer-1.0", base / "../lib/gstreamer-1.0" }) {
        std::error_code error;
        const auto path = std::filesystem::canonical(candidate, error);
        if (error || !std::filesystem::is_directory(path, error) || error) { continue; }
        const auto utf8 = path.generic_u8string();
        return { reinterpret_cast<const char *>(utf8.data()), utf8.size() };
    }
    return {};
}

void configure()
{
    static std::once_flag once;
    std::call_once(once, [] {
        const auto plugins = plugin_dir();
        if (plugins.empty()) { return; }
        g_setenv("GST_PLUGIN_PATH_1_0", plugins.c_str(), FALSE);
        g_setenv("GST_PLUGIN_SYSTEM_PATH_1_0", "", FALSE);
        g_setenv("GST_REGISTRY_FORK", "no", FALSE);
    });
}
}
#endif
