module;

#ifdef _WIN32
#include "bundled_gstreamer.hpp"
#endif
#include <atomic>
#include <cstddef>
#include <gst/gst.h>
#include <mutex>
#include <string>

module kataglyphis.gstreamer_runtime;

import kataglyphis.log;

namespace kataglyphis::gstreamer::runtime {

namespace {
    struct State
    {
        std::mutex mutex;
        std::atomic<bool> initialized{ false };
        // gst_init cannot run again after gst_deinit, so a second initialise must fail rather than crash.
        bool deinitialized = false;
        std::atomic<bool> plugin_scanner_failed{ false };
        std::atomic<std::size_t> live_pipelines{ 0 };
    };

    // The new pipeline holds the element's one reference: gst_bin_add refs an element that is not floating.
    auto wrap_in_pipeline(GstElement *element) -> GstElement *
    {
        GstElement *pipeline = gst_pipeline_new(nullptr);
        gst_object_ref_sink(pipeline);
        gst_bin_add(GST_BIN(pipeline), element);
        gst_object_unref(element);
        return pipeline;
    }

    auto state() -> State &
    {
        static State the_state;
        return the_state;
    }

    // GStreamer falls back to an in-process scan on a broken scanner, and only this warning says so.
    void note_plugin_scanner_failure(const gchar *domain, GLogLevelFlags level, const gchar *message, gpointer data)
    {
        if (message != nullptr && g_str_has_prefix(message, "External plugin loader failed")) {
            state().plugin_scanner_failed.store(true);
        }
        g_log_default_handler(domain, level, message, data);
    }
}// namespace

auto initialize(int *argc, char ***argv) -> bool
{
    const std::scoped_lock lock(state().mutex);
    if (state().initialized.load()) { return true; }
    if (state().deinitialized) {
        log::error("GStreamer was deinitialised in this process, and gst_init cannot run again");
        return false;
    }
    const guint scan_log = g_log_set_handler("GStreamer", G_LOG_LEVEL_WARNING, note_plugin_scanner_failure, nullptr);
#ifdef _WIN32
    bundled_gstreamer::configure();
#endif
    GError *error = nullptr;
    const bool started = gst_init_check(argc, argv, &error) != 0;
    g_log_remove_handler("GStreamer", scan_log);
    if (!started) {
        // GLib's words are the only reason a caller gets: the code says no more than that the init failed.
        log::error("GStreamer init failed: {}", error != nullptr ? error->message : "no reason given");
        if (error != nullptr) { g_error_free(error); }
        return false;
    }
    state().initialized.store(true);
    return true;
}

auto is_initialized() -> bool { return state().initialized.load(); }

auto plugin_scanner_failed() -> bool { return state().plugin_scanner_failed.load(); }

auto deinitialize() -> bool
{
    const std::scoped_lock lock(state().mutex);
    if (!state().initialized.load()) { return false; }
    if (const std::size_t live = state().live_pipelines.load(); live != 0) {
        log::warning("GStreamer stays initialised: {} pipeline(s) still alive", live);
        return false;
    }
    gst_deinit();
    state().initialized.store(false);
    state().deinitialized = true;
    return true;
}

auto parse_launch(const std::string &description, const char *failure_context) -> GstElement *
{
    GError *error = nullptr;
    GstElement *pipeline = gst_parse_launch(description.c_str(), &error);
    // gst_parse_launch hands out a floating reference; sinking it makes release()'s unref the matching one.
    if (pipeline != nullptr) { gst_object_ref_sink(pipeline); }
    if (error != nullptr) {
        log::error("{}: {}", failure_context, error->message);
        g_error_free(error);
        if (pipeline != nullptr) { gst_object_unref(pipeline); }
        return nullptr;
    }
    if (pipeline == nullptr) {
        log::error("{} returned null", failure_context);
        return nullptr;
    }
    // A lone element comes back bare and has no bus until it sits in a pipeline, so nothing could read its errors.
    if (!GST_IS_PIPELINE(pipeline)) { pipeline = wrap_in_pipeline(pipeline); }
    state().live_pipelines.fetch_add(1);
    return pipeline;
}

auto release(GstElement *pipeline) -> void
{
    if (pipeline == nullptr) { return; }
    gst_object_unref(pipeline);
    state().live_pipelines.fetch_sub(1);
}

}// namespace kataglyphis::gstreamer::runtime
