#pragma once

// Standalone programs isolate packaged plugins; library embedders retain their environment.
#if defined(_WIN32)
#include <cstdlib>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

namespace kataglyphis::standalone_gstreamer {

inline auto isolate_packaged_plugins() -> bool
{
    std::vector<wchar_t> filename(32768);
    const DWORD length = GetModuleFileNameW(nullptr, filename.data(), static_cast<DWORD>(filename.size()));
    if (length == 0 || length >= filename.size()) { return false; }
    const auto bin = std::filesystem::path(std::wstring(filename.data(), length)).parent_path();
    bool packaged = false;
    for (const auto &candidate : { bin / "gstreamer-1.0", bin / "lib/gstreamer-1.0", bin / "../lib/gstreamer-1.0" }) {
        std::error_code error;
        if (std::filesystem::is_directory(candidate, error) && !error) {
            packaged = true;
            break;
        }
    }
    if (!packaged) { return true; }
    for (const wchar_t *name : { L"GST_PLUGIN_PATH",
           L"GST_PLUGIN_PATH_1_0",
           L"GST_PLUGIN_SYSTEM_PATH",
           L"GST_PLUGIN_SYSTEM_PATH_1_0",
           L"GST_PLUGIN_SCANNER",
           L"GST_PLUGIN_SCANNER_1_0",
           L"GST_REGISTRY",
           L"GST_REGISTRY_1_0",
           L"GST_REGISTRY_FORK" }) {
        if (_wputenv_s(name, L"") != 0) { return false; }
    }
    return true;
}

}// namespace kataglyphis::standalone_gstreamer
#endif
