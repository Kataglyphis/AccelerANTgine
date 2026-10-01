#ifndef KATAGLYPHIS_GSTREAMER_TEST_SUPPORT_H
#define KATAGLYPHIS_GSTREAMER_TEST_SUPPORT_H

// No includes of its own: include it after the std headers it uses and `import kataglyphis.gstreamer_pipeline;`.

namespace kataglyphis::test {

// The first element GStreamer cannot create, probed through the library itself; empty when all exist.
inline auto missing_gstreamer_element(std::initializer_list<std::string_view> elements) -> std::string
{
    if (!kataglyphis::gstreamer::GStreamerPipeline::initialize_gstreamer()) { return "gst_init"; }
    for (const auto element : elements) {
        kataglyphis::gstreamer::GStreamerPipeline probe;
        if (!probe.create_pipeline_from_string(std::string(element))) { return std::string(element); }
    }
    return {};
}

// Counts events from GStreamer's streaming thread and lets the test thread wait for a total.
class EventCounter
{
  public:
    // Notifies under the lock: once the waiter sees the count, add() no longer touches the condition variable.
    void add()
    {
        std::scoped_lock lock(mutex_);
        ++count_;
        changed_.notify_all();
    }

    [[nodiscard]] auto wait_for(int expected, std::chrono::milliseconds timeout) -> bool
    {
        std::unique_lock lock(mutex_);
        return changed_.wait_for(lock, timeout, [&] { return count_ >= expected; });
    }

    [[nodiscard]] auto count() -> int
    {
        std::scoped_lock lock(mutex_);
        return count_;
    }

  private:
    std::mutex mutex_;
    std::condition_variable changed_;
    int count_{ 0 };
};

// Generous on purpose: the riscv64 lane runs these under QEMU, the Linux lanes under ASan or TSan.
inline constexpr std::chrono::milliseconds kStreamTimeout{ 60000 };

}// namespace kataglyphis::test

// Skips the running test, naming the element, where this GStreamer install lacks it.
#define KATAGLYPHIS_REQUIRE_GSTREAMER_ELEMENTS(...)                                                       \
    do {                                                                                                  \
        const auto kataglyphis_missing = ::kataglyphis::test::missing_gstreamer_element({ __VA_ARGS__ }); \
        if (!kataglyphis_missing.empty()) {                                                               \
            GTEST_SKIP() << "GStreamer element '" << kataglyphis_missing << "' is not installed here";    \
        }                                                                                                 \
    } while (false)

#endif// KATAGLYPHIS_GSTREAMER_TEST_SUPPORT_H
