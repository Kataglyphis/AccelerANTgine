#pragma once

// A copy to the GPU that never returns (hub CON202) would block MIGraphX and this process's exit, so a child makes it.
#ifndef _WIN32

#include <dlfcn.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <thread>

namespace kataglyphis::inference::hip_probe {

inline constexpr const char *runtime = "libamdhip64.so.7";
inline constexpr std::chrono::seconds answer_limit{ 30 };

// False only when `work` outlives `limit`: MIGraphX reports a child that crashed or could not start.
template<typename Work> auto answers_within(std::chrono::milliseconds limit, Work work) -> bool
{
    const pid_t child = fork();
    if (child == 0) {
        work();
        _exit(0);
    }
    if (child < 0) { return true; }
    const auto deadline = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < deadline) {
        if (waitpid(child, nullptr, WNOHANG) != 0) { return true; }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    kill(child, SIGKILL);
    // A child stuck in the driver may take its time to die; nothing here waits for that.
    std::thread([child] { waitpid(child, nullptr, 0); }).detach();
    return false;
}

// No runtime, no such device or a failed allocation returns: MIGraphX reports those.
inline void copy_to_device(const char *library, int device)
{
    using Init = int (*)(unsigned int);
    using SetDevice = int (*)(int);
    using Malloc = int (*)(void **, std::size_t);
    using Memcpy = int (*)(void *, const void *, std::size_t, int);
    constexpr int host_to_device = 1;

    void *hip = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (hip == nullptr) { return; }
    const auto init = reinterpret_cast<Init>(dlsym(hip, "hipInit"));
    const auto set_device = reinterpret_cast<SetDevice>(dlsym(hip, "hipSetDevice"));
    const auto malloc_on_device = reinterpret_cast<Malloc>(dlsym(hip, "hipMalloc"));
    const auto copy = reinterpret_cast<Memcpy>(dlsym(hip, "hipMemcpy"));
    if (init == nullptr || set_device == nullptr || malloc_on_device == nullptr || copy == nullptr) { return; }
    void *on_device = nullptr;
    const std::uint32_t value = 0;
    if (init(0) == 0 && set_device(device) == 0 && malloc_on_device(&on_device, sizeof(value)) == 0) {
        copy(on_device, &value, sizeof(value), host_to_device);
    }
}

}// namespace kataglyphis::inference::hip_probe

#endif
