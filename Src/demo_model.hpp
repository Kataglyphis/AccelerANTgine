#pragma once

#include <filesystem>
#include <system_error>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <string>
#include <vector>
#include <windows.h>
#endif

namespace kataglyphis::demo {

inline auto default_model_from_executable(const std::filesystem::path &executable,
  bool windows,
  bool required,
  const std::filesystem::path &from_private,
  const std::filesystem::path &from_bin) -> std::filesystem::path
{
    if (executable.empty()) {
        if (required) { return {}; }
        return "models/deim_dfine_n_coco.onnx";
    }
    const auto directory = executable.parent_path();
    const auto bundled = directory / (windows ? std::filesystem::path("models/deim_dfine_n_coco.onnx") : from_private);
    std::error_code error;
    if (std::filesystem::is_regular_file(bundled, error) && !error) { return bundled; }
    const auto installed = directory / from_bin;
    error.clear();
    if (!windows && std::filesystem::is_regular_file(installed, error) && !error) { return installed; }
    if (required) { return bundled; }
    return "models/deim_dfine_n_coco.onnx";
}

inline auto default_model() -> std::filesystem::path
{
#if defined(KATAGLYPHIS_BUNDLED_DEMO_MODEL)
    constexpr bool required = true;
#else
    constexpr bool required = false;
#endif
#if defined(KATAGLYPHIS_DEMO_MODEL_FROM_PRIVATE) && defined(KATAGLYPHIS_DEMO_MODEL_FROM_BIN)
    const std::filesystem::path from_private = KATAGLYPHIS_DEMO_MODEL_FROM_PRIVATE;
    const std::filesystem::path from_bin = KATAGLYPHIS_DEMO_MODEL_FROM_BIN;
#else
    const std::filesystem::path from_private;
    const std::filesystem::path from_bin;
#endif
#if defined(_WIN32)
    std::vector<wchar_t> filename(32768);
    const DWORD length = GetModuleFileNameW(nullptr, filename.data(), static_cast<DWORD>(filename.size()));
    if (length == 0 || length >= filename.size()) {
        return default_model_from_executable({}, true, required, from_private, from_bin);
    }
    return default_model_from_executable(
      std::filesystem::path(std::wstring(filename.data(), length)), true, required, from_private, from_bin);
#elif defined(__linux__)
    std::error_code error;
    const auto executable = std::filesystem::read_symlink("/proc/self/exe", error);
    return default_model_from_executable(
      error ? std::filesystem::path{} : executable, false, required, from_private, from_bin);
#else
    return default_model_from_executable({}, false, required, from_private, from_bin);
#endif
}

}// namespace kataglyphis::demo
