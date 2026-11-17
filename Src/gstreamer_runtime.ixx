module;

#include <string>

// GStreamer's element type without its headers in this interface.
struct _GstElement;

export module kataglyphis.gstreamer_runtime;

// The process's one GStreamer owner: both pipeline classes initialise, parse and deinitialise through it.
export namespace kataglyphis::gstreamer::runtime {

// Initialises GStreamer once and records whether its plugin scanner failed; false after a logged failure.
[[nodiscard]] auto initialize(int *argc, char ***argv) -> bool;

[[nodiscard]] auto is_initialized() -> bool;

// True when initialisation saw GStreamer give up on its plugin scanner and scan in process.
[[nodiscard]] auto plugin_scanner_failed() -> bool;

// gst_deinit, refused while a pipeline from parse_launch lives; it is final for the process.
[[nodiscard]] auto deinitialize() -> bool;

// A parsed pipeline with its floating reference sunk, counted as alive until release(); nullptr after a logged failure.
[[nodiscard]] auto parse_launch(const std::string &description, const char *failure_context) -> _GstElement *;

auto release(_GstElement *pipeline) -> void;

}// namespace kataglyphis::gstreamer::runtime
