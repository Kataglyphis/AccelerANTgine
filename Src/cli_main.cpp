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
ABSL_FLAG(std::string, source, "libcamera", "Video source: libcamera, v4l2, test, file, uri");
ABSL_FLAG(std::string, device, "/dev/video0", "V4L2 device path");
ABSL_FLAG(std::string, camera_id, "", "Libcamera camera name");
ABSL_FLAG(std::string, input_path, "", "Local media file path for --source file");
ABSL_FLAG(std::string, input_uri, "", "Media URI for --source uri");
ABSL_FLAG(std::uint32_t, width, 0, "Video width in pixels (0 = use config default)");
ABSL_FLAG(std::uint32_t, height, 0, "Video height in pixels (0 = use config default)");
ABSL_FLAG(std::uint32_t, fps, 0, "Framerate (0 = use config default)");
ABSL_FLAG(std::string, encoder, "h264-hw", "Encoder: h264-hw, h264-sw, vp8, vp9");
ABSL_FLAG(std::uint32_t, bitrate, 0, "Bitrate in kbps (0 = use config default)");

namespace {
    std::atomic<bool> g_running{ true };

    struct CliOverrideFlags {
        bool server{ false };
        bool source{ false };
        bool device{ false };
        bool camera_id{ false };
        bool input_path{ false };
        bool input_uri{ false };
        bool width{ false };
        bool height{ false };
        bool fps{ false };
        bool encoder{ false };
        bool bitrate{ false };
    };

    void signal_handler(int /*signal*/)
    {
        g_running.store(false);
    }

    auto was_flag_provided(std::string_view argument, std::string_view flag_name) -> bool
    {
        const std::string long_flag = "--" + std::string(flag_name);
        const std::string short_flag = "-" + std::string(flag_name);
        return argument == long_flag || argument.starts_with(long_flag + "=") || argument == short_flag ||
               argument.starts_with(short_flag + "=");
    }

    auto detect_cli_override_flags(int argc, char **argv) -> CliOverrideFlags
    {
        CliOverrideFlags flags;

        for (int index = 1; index < argc; ++index) {
            const std::string_view argument = argv[index];
            flags.server = flags.server || was_flag_provided(argument, "server");
            flags.source = flags.source || was_flag_provided(argument, "source");
            flags.device = flags.device || was_flag_provided(argument, "device");
            flags.camera_id = flags.camera_id || was_flag_provided(argument, "camera_id") ||
                              was_flag_provided(argument, "camera-id");
            flags.input_path = flags.input_path || was_flag_provided(argument, "input_path") ||
                               was_flag_provided(argument, "input-path");
            flags.input_uri = flags.input_uri || was_flag_provided(argument, "input_uri") ||
                              was_flag_provided(argument, "input-uri");
            flags.width = flags.width || was_flag_provided(argument, "width");
            flags.height = flags.height || was_flag_provided(argument, "height");
            flags.fps = flags.fps || was_flag_provided(argument, "fps");
            flags.encoder = flags.encoder || was_flag_provided(argument, "encoder");
            flags.bitrate = flags.bitrate || was_flag_provided(argument, "bitrate");
        }

        return flags;
    }

    auto parse_video_source(std::string_view name) -> kataglyphis::webrtc::VideoSource
    {
        if (name == "v4l2") { return kataglyphis::webrtc::VideoSource::V4L2; }
        if (name == "test") { return kataglyphis::webrtc::VideoSource::TestPattern; }
        if (name == "file") { return kataglyphis::webrtc::VideoSource::File; }
        if (name == "uri") { return kataglyphis::webrtc::VideoSource::Uri; }
        if (name != "libcamera") {
            std::cerr << "Warning: unknown source '" << name << "', falling back to libcamera\n";
        }
        return kataglyphis::webrtc::VideoSource::Libcamera;
    }

    auto parse_video_encoder(std::string_view name) -> kataglyphis::webrtc::VideoEncoder
    {
        if (name == "h264-sw") { return kataglyphis::webrtc::VideoEncoder::H264_Software; }
        if (name == "vp8") { return kataglyphis::webrtc::VideoEncoder::VP8; }
        if (name == "vp9") { return kataglyphis::webrtc::VideoEncoder::VP9; }
        if (name != "h264-hw") {
            std::cerr << "Warning: unknown encoder '" << name << "', falling back to h264-hw\n";
        }
        return kataglyphis::webrtc::VideoEncoder::H264_Hardware;
    }

    auto state_to_string(kataglyphis::webrtc::StreamState state) -> const char *
    {
        using kataglyphis::webrtc::StreamState;
        switch (state) {
        case StreamState::Idle:
            return "Idle";
        case StreamState::Connecting:
            return "Connecting";
        case StreamState::Negotiating:
            return "Negotiating";
        case StreamState::Streaming:
            return "Streaming";
        case StreamState::Paused:
            return "Paused";
        case StreamState::Error:
            return "Error";
        case StreamState::Disconnected:
            return "Disconnected";
        }
        return "Unknown";
    }

    auto apply_cli_overrides(kataglyphis::webrtc::StreamConfig &config, const CliOverrideFlags &override_flags) -> void
    {
        if (override_flags.server) {
            const auto cli_server = absl::GetFlag(FLAGS_server);
            config.signalling_server_uri = cli_server;
        }
        if (override_flags.device) { config.v4l2_device = absl::GetFlag(FLAGS_device); }
        if (override_flags.camera_id) { config.camera_id = absl::GetFlag(FLAGS_camera_id); }
        if (override_flags.input_path) { config.input_path = absl::GetFlag(FLAGS_input_path); }
        if (override_flags.input_uri) { config.input_uri = absl::GetFlag(FLAGS_input_uri); }
        if (override_flags.width) { config.width = absl::GetFlag(FLAGS_width); }
        if (override_flags.height) { config.height = absl::GetFlag(FLAGS_height); }
        if (override_flags.fps) { config.framerate = absl::GetFlag(FLAGS_fps); }
        if (override_flags.bitrate) {
            const auto cli_bitrate = absl::GetFlag(FLAGS_bitrate);
            config.bitrate_kbps = cli_bitrate;
        }
    }
}  // namespace

auto main(int argc, char** argv) -> int
{
    const auto override_flags = detect_cli_override_flags(argc, argv);

    absl::SetProgramUsageMessage(
        "KataglyphisCppInference — WebRTC streaming and inference engine\n\n"
        "Examples:\n"
        "  --webrtc --config /path/to/webrtc_settings.json\n"
        "  --webrtc --server ws://192.168.1.100:8443\n"
        "  --webrtc --source v4l2 --device /dev/video0\n"
        "  --webrtc --source file --input_path /path/to/video.mp4\n"
        "  --webrtc --source uri --input_uri rtsp://camera.example/stream\n"
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

    const auto source = parse_video_source(absl::GetFlag(FLAGS_source));
    const auto encoder = parse_video_encoder(absl::GetFlag(FLAGS_encoder));
    const auto source_override_mode = override_flags.source ? kataglyphis::webrtc::ConfigOverrideMode::Override
                                                            : kataglyphis::webrtc::ConfigOverrideMode::UseConfig;
    const auto encoder_override_mode = override_flags.encoder ? kataglyphis::webrtc::ConfigOverrideMode::Override
                                                              : kataglyphis::webrtc::ConfigOverrideMode::UseConfig;
    auto webrtc_config = kataglyphis::config::get_default_webrtc_config();

    const std::string config_file_path = absl::GetFlag(FLAGS_config);

    if (!config_file_path.empty()) {
        std::cout << "Loading configuration from: " << config_file_path << '\n';
        auto result = kataglyphis::config::load_webrtc_config(config_file_path);
        if (result) {
            webrtc_config = *result;
            std::cout << "Configuration loaded successfully\n";
        } else {
            std::cerr << "Warning: Failed to load config file, using defaults\n";
        }
    }

    auto config = kataglyphis::webrtc::create_stream_config_from_webrtc_config(
        webrtc_config,
        source,
        encoder,
        source_override_mode,
        encoder_override_mode
    );

    apply_cli_overrides(config, override_flags);

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
