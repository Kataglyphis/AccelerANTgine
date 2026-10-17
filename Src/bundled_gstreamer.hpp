#pragma once

#include <string>

namespace kataglyphis::bundled_gstreamer {

/// The `gstreamer-1.0` directory a Linux package carries for this library; empty anywhere else.
auto plugin_dir() -> std::string;

}// namespace kataglyphis::bundled_gstreamer
