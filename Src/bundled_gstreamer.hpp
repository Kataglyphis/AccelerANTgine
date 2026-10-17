#pragma once

#include <string>

namespace kataglyphis::bundled_gstreamer {

/// The `gstreamer-1.0` directory beside this library in a Linux package; empty anywhere else.
auto plugin_dir() -> std::string;

}// namespace kataglyphis::bundled_gstreamer
