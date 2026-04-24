#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>

#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/flags/usage.h"

import kataglyphis.inference;
import kataglyphis.webrtc_streamer;
import kataglyphis.config_loader;

ABSL_FLAG(bool, webrtc, false, "Start WebRTC streaming");
ABSL_FLAG(std::string, config, "", "Load settings from JSON config file");
ABSL_FLAG(std::string, server, "ws://127.0.0.1:8443", "Signalling server URI");
ABSL_FLAG(std::string, source, "libcamera", "Video source: libcamera, v4l2, test");
ABSL_FLAG(std::string, device, "/dev/video0", "V4L2 device path");
ABSL_FLAG(std::uint32_t, width, 1280, "Video width in pixels");
ABSL_FLAG(std::uint32_t, height, 720, "Video height in pixels");
ABSL_FLAG(std::uint32_t, fps, 30, "Framerate");
ABSL_FLAG(std::string, encoder, "h264-hw", "Encoder: h264-hw, h264-sw, vp8, vp9");
ABSL_FLAG(std::uint32_t, bitrate, 2000, "Bitrate in kbps");

namespace {
    volatile std::sig_atomic_t g_running = 1;

    void signal_handler(int /*signal*/) {
        g_running = 0;
    }

    auto parse_video_source(const std::string& name) -> kataglyphis::webrtc::VideoSource {
        if (name == "v4l2") { return kataglyphis::webrtc::VideoSource::V4L2;
}
        if (name == "test") { return kataglyphis::webrtc::VideoSource::TestPattern;
}
        return kataglyphis::webrtc::VideoSource::Libcamera;
    }

    auto parse_video_encoder(const std::string& name) -> kataglyphis::webrtc::VideoEncoder {
        if (name == "h264-sw") { return kataglyphis::webrtc::VideoEncoder::H264_Software;
}
        if (name == "vp8") { return kataglyphis::webrtc::VideoEncoder::VP8;
}
        if (name == "vp9") { return kataglyphis::webrtc::VideoEncoder::VP9;
}
        return kataglyphis::webrtc::VideoEncoder::H264_Hardware;
    }

    auto state_to_string(kataglyphis::webrtc::StreamState state) -> const char* {
        using kataglyphis::webrtc::StreamState;
        switch (state) {
            case StreamState::Idle: return "Idle";
            case StreamState::Connecting: return "Connecting";
            case StreamState::Negotiating: return "Negotiating";
            case StreamState::Streaming: return "Streaming";
            case StreamState::Paused: return "Paused";
            case StreamState::Error: return "Error";
            case StreamState::Disconnected: return "Disconnected";
        }
        return "Unknown";
    }
}  // namespace

auto main(int argc, char** argv) -> int
{
    absl::SetProgramUsageMessage(
        "KataglyphisCppInference — WebRTC streaming and inference engine\n\n"
        "Examples:\n"
        "  --webrtc --config /path/to/webrtc_settings.json\n"
        "  --webrtc --server ws://192.168.1.100:8443\n"
        "  --webrtc --source v4l2 --device /dev/video0\n"
        "  --webrtc --source test   # For testing without camera");

    absl::ParseCommandLine(argc, argv);

    mylib::MyCalculator calculator;

    const bool start_webrtc = absl::GetFlag(FLAGS_webrtc);
    if (!start_webrtc) {
        std::cout << "KataglyphisCppInference " << calculator.version() << '\n';
        std::cout << "Use --help for usage information\n";
        return 0;
    }

    kataglyphis::webrtc::StreamConfig config;
    config.source = parse_video_source(absl::GetFlag(FLAGS_source));
    config.encoder = parse_video_encoder(absl::GetFlag(FLAGS_encoder));
    config.signalling_server_uri = absl::GetFlag(FLAGS_server);
    config.v4l2_device = absl::GetFlag(FLAGS_device);
    config.width = absl::GetFlag(FLAGS_width);
    config.height = absl::GetFlag(FLAGS_height);
    config.framerate = absl::GetFlag(FLAGS_fps);
    config.bitrate_kbps = absl::GetFlag(FLAGS_bitrate);

    const std::string config_file_path = absl::GetFlag(FLAGS_config);

    std::cout << "Initializing WebRTC streaming...\n";

    auto init_result = kataglyphis::webrtc::WebRTCStreamer::initialize(&argc, &argv);
    if (!init_result) {
        std::cerr << "Failed to initialize GStreamer for WebRTC\n";
        return 1;
    }

    if (!config_file_path.empty()) {
        std::cout << "Loading configuration from: " << config_file_path << '\n';
        auto webrtc_config_result = kataglyphis::config::load_webrtc_config(config_file_path);
        if (webrtc_config_result) {
            const auto& webrtc_config = webrtc_config_result.value();
            if (config.signalling_server_uri == "ws://127.0.0.1:8443") {
                config.signalling_server_uri = webrtc_config.signaling_server_url;
            }
            if (config.width == 1280) {
                config.width = webrtc_config.video.default_width;
            }
            if (config.height == 720) {
                config.height = webrtc_config.video.default_height;
            }
            if (config.framerate == 30) {
                config.framerate = webrtc_config.video.default_framerate;
            }
            if (config.bitrate_kbps == 2000) {
                config.bitrate_kbps = webrtc_config.video.default_bitrate_kbps;
            }
            config.stun_servers = webrtc_config.stun_servers;
            config.turn_servers = webrtc_config.turn_servers;
            std::cout << "Configuration loaded successfully\n";
        } else {
            std::cerr << "Warning: Failed to load config file, using defaults\n";
        }
    }

    kataglyphis::webrtc::WebRTCStreamer streamer;

    streamer.set_state_callback([](kataglyphis::webrtc::StreamState old_state,
                                   kataglyphis::webrtc::StreamState new_state) -> void {
        std::cout << "State: " << state_to_string(old_state)
                  << " -> " << state_to_string(new_state) << '\n';
    });

    streamer.set_error_callback([](kataglyphis::webrtc::WebRTCError /*error*/,
                                   const std::string& message) -> void {
        std::cerr << "Error: " << message << '\n';
    });

    auto configure_result = streamer.configure(config);
    if (!configure_result) {
        std::cerr << "Failed to configure WebRTC streamer\n";
        return 1;
    }

    std::cout << "Connecting to signalling server: " << config.signalling_server_uri << '\n';
    std::cout << "Producer ID: " << streamer.get_producer_id() << '\n';
    std::cout << "Resolution: " << config.width << "x" << config.height << "@" << config.framerate << "fps\n";

    auto start_result = streamer.start();
    if (!start_result) {
        std::cerr << "Failed to start WebRTC stream\n";
        return 1;
    }

    (void)std::signal(SIGINT, signal_handler);
    (void)std::signal(SIGTERM, signal_handler);

    std::cout << "Streaming... Press Ctrl+C to stop.\n";

    while (g_running != 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        auto state = streamer.get_state();
        if (state == kataglyphis::webrtc::StreamState::Error ||
            state == kataglyphis::webrtc::StreamState::Disconnected) {
            std::cerr << "Stream ended unexpectedly\n";
            break;
        }
    }

    std::cout << "\nStopping stream...\n";
    (void)streamer.stop();

    kataglyphis::webrtc::WebRTCStreamer::deinitialize();

    std::cout << "Done.\n";
    return 0;
}