#include <atomic>
#include <chrono>
#include <csignal>
#include <iostream>
#include <string>
#include <string_view>
#include <thread>

#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/flags/usage.h"

import kataglyphis.inference;
import kataglyphis.webrtc_streamer;
import kataglyphis.config_loader;
import kataglyphis.project_config;

ABSL_FLAG(bool, webrtc, false, "Start WebRTC streaming");
ABSL_FLAG(std::string, config, "", "Load settings from JSON config file");
ABSL_FLAG(std::string, server, "", "Signalling server URI (overrides config file default)");
ABSL_FLAG(std::string, source, "libcamera", "Video source: libcamera, v4l2, test");
ABSL_FLAG(std::string, device, "/dev/video0", "V4L2 device path");
ABSL_FLAG(std::uint32_t, width, 0, "Video width in pixels (0 = use config default)");
ABSL_FLAG(std::uint32_t, height, 0, "Video height in pixels (0 = use config default)");
ABSL_FLAG(std::uint32_t, fps, 0, "Framerate (0 = use config default)");
ABSL_FLAG(std::string, encoder, "h264-hw", "Encoder: h264-hw, h264-sw, vp8, vp9");
ABSL_FLAG(std::uint32_t, bitrate, 0, "Bitrate in kbps (0 = use config default)");

namespace {
    std::atomic<bool> g_running{true};

    void signal_handler(int /*signal*/) {
        g_running.store(false);
    }

    auto parse_video_source(std::string_view name) -> kataglyphis::webrtc::VideoSource {
        if (name == "v4l2") { return kataglyphis::webrtc::VideoSource::V4L2; }
        if (name == "test") { return kataglyphis::webrtc::VideoSource::TestPattern; }
        if (name != "libcamera") {
            std::cerr << "Warning: unknown source '" << name << "', falling back to libcamera\n";
        }
        return kataglyphis::webrtc::VideoSource::Libcamera;
    }

    auto parse_video_encoder(std::string_view name) -> kataglyphis::webrtc::VideoEncoder {
        if (name == "h264-sw") { return kataglyphis::webrtc::VideoEncoder::H264_Software; }
        if (name == "vp8") { return kataglyphis::webrtc::VideoEncoder::VP8; }
        if (name == "vp9") { return kataglyphis::webrtc::VideoEncoder::VP9; }
        if (name != "h264-hw") {
            std::cerr << "Warning: unknown encoder '" << name << "', falling back to h264-hw\n";
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

    const bool start_webrtc = absl::GetFlag(FLAGS_webrtc);
    if (!start_webrtc) {
        std::cout << "KataglyphisCppInference "
                  << kataglyphis::project_config::project_version_major << "."
                  << kataglyphis::project_config::project_version_minor << '\n';
        std::cout << "Use --help for usage information\n";
        return 0;
    }

    kataglyphis::webrtc::StreamConfig config;
    config.source = parse_video_source(absl::GetFlag(FLAGS_source));
    config.encoder = parse_video_encoder(absl::GetFlag(FLAGS_encoder));
    config.v4l2_device = absl::GetFlag(FLAGS_device);

    const std::string config_file_path = absl::GetFlag(FLAGS_config);

    kataglyphis::config::WebRTCConfig webrtc_config;

    if (!config_file_path.empty()) {
        std::cout << "Loading configuration from: " << config_file_path << '\n';
        auto result = kataglyphis::config::load_webrtc_config(config_file_path);
        if (result) {
            webrtc_config = *result;
            config.signalling_server_uri = webrtc_config.signaling_server_url;
            config.width = webrtc_config.video.default_width;
            config.height = webrtc_config.video.default_height;
            config.framerate = webrtc_config.video.default_framerate;
            config.bitrate_kbps = webrtc_config.video.default_bitrate_kbps;
            config.stun_servers = webrtc_config.stun_servers;
            config.turn_servers = webrtc_config.turn_servers;
            std::cout << "Configuration loaded successfully\n";
        } else {
            std::cerr << "Warning: Failed to load config file, using defaults\n";
        }
    }

    const std::string cli_server = absl::GetFlag(FLAGS_server);
    const std::uint32_t cli_width = absl::GetFlag(FLAGS_width);
    const std::uint32_t cli_height = absl::GetFlag(FLAGS_height);
    const std::uint32_t cli_fps = absl::GetFlag(FLAGS_fps);
    const std::uint32_t cli_bitrate = absl::GetFlag(FLAGS_bitrate);

    if (!cli_server.empty()) { config.signalling_server_uri = cli_server; }
    if (cli_width != 0) { config.width = cli_width; }
    if (cli_height != 0) { config.height = cli_height; }
    if (cli_fps != 0) { config.framerate = cli_fps; }
    if (cli_bitrate != 0) { config.bitrate_kbps = cli_bitrate; }

    std::cout << "Initializing WebRTC streaming...\n";

    auto init_result = kataglyphis::webrtc::WebRTCStreamer::initialize(&argc, &argv);
    if (!init_result) {
        std::cerr << "Failed to initialize GStreamer for WebRTC\n";
        return 1;
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

    while (g_running.load()) {
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