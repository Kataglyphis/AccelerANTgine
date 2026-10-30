#pragma once

#include <string>

namespace kataglyphis::bundled_gstreamer {

/// The package plugin directory for this library, or empty in an unpackaged build.
auto plugin_dir() -> std::string;
#if defined(_WIN32)
void configure();
#endif

}// namespace kataglyphis::bundled_gstreamer
