#pragma once

// One kernel first: third_party/ANTfrastructure/docs/linux-accelerator-images.md#a-card-without-a-cuda-kernel
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include <array>
#include <optional>
#include <string>
#include <string_view>

namespace kataglyphis::inference::cuda_probe {

// A single float Relu with input x: ONNX Runtime's own CUDA code, not a vendor library with its own kernels.
inline constexpr std::string_view one_kernel =
  "\x08\x08\x3a\x33\x0a\x0c\x0a\x01\x78\x12\x01\x79\x22\x04\x52\x65\x6c\x75\x12\x01"
  "\x70\x5a\x0f\x0a\x01\x78\x12\x0a\x0a\x08\x08\x01\x12\x04\x0a\x02\x08\x01\x62\x0f"
  "\x0a\x01\x79\x12\x0a\x0a\x08\x08\x01\x12\x04\x0a\x02\x08\x01\x42\x02\x10\x0d";

#if defined(_WIN32)
inline constexpr const char *driver = "nvcuda.dll";
#else
inline constexpr const char *driver = "libcuda.so.1";
#endif

// The card's name and compute capability as the driver reports them; empty without a driver that answers.
inline auto card_on(const char *library, int device_id) -> std::optional<std::string>
{
    using Init = int (*)(unsigned int);
    using DeviceGet = int (*)(int *, int);
    using DeviceName = int (*)(char *, int, int);
    using Capability = int (*)(int *, int *, int);

#if defined(_WIN32)
    const HMODULE cuda = LoadLibraryA(library);
    const auto symbol = [cuda](
                          const char *name) -> void * { return reinterpret_cast<void *>(GetProcAddress(cuda, name)); };
#else
    void *cuda = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    const auto symbol = [cuda](const char *name) -> void * { return dlsym(cuda, name); };
#endif
    if (cuda == nullptr) { return std::nullopt; }
    const auto init = reinterpret_cast<Init>(symbol("cuInit"));
    const auto device_get = reinterpret_cast<DeviceGet>(symbol("cuDeviceGet"));
    const auto device_name = reinterpret_cast<DeviceName>(symbol("cuDeviceGetName"));
    const auto capability = reinterpret_cast<Capability>(symbol("cuDeviceComputeCapability"));
    if (init == nullptr || device_get == nullptr || device_name == nullptr || capability == nullptr) {
        return std::nullopt;
    }
    int device = 0;
    std::array<char, 256> name{};
    int major = 0;
    int minor = 0;
    if (init(0) != 0 || device_get(&device, device_id) != 0
        || device_name(name.data(), static_cast<int>(name.size()), device) != 0
        || capability(&major, &minor, device) != 0) {
        return std::nullopt;
    }
    return std::string(name.data()) + " (compute capability " + std::to_string(major) + "." + std::to_string(minor)
           + ")";
}

// Why CUDA cannot run, only when the card has no kernel; CUDA reports every other failure when the real session starts.
template<typename Card> auto no_kernel_reason(std::string_view run_error, Card card) -> std::optional<std::string>
{
    if (run_error.find("cudaErrorNoKernelImageForDevice") == std::string_view::npos) { return std::nullopt; }
    const std::optional<std::string> named = card();
    return "CUDAExecutionProvider cannot run on " + named.value_or("this NVIDIA GPU")
           + ": this ONNX Runtime has no CUDA kernel for it. The cpu device runs on the CPU";
}

}// namespace kataglyphis::inference::cuda_probe
