#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>

import kataglyphis.inference;
import kataglyphis.webrtc_streamer;
import kataglyphis.config_loader;

namespace {
    volatile std::sig_atomic_t g_running = 1;
    
    void signal_handler(int /*signal*/) {
        g_running = 0;
    }
    
    void print_usage(const char* program) {
        std::cout << "Usage: " << program << " [OPTIONS]\n"
                  << "\nOptions:\n"
                  << "  --help, -h              Show this help message\n"
                  << "  --version, -v           Show version information\n"
                  << "  --webrtc                Start WebRTC streaming\n"
                  << "  --config <path>         Load settings from JSON config file\n"
                  << "  --server <uri>          Signalling server URI (default: ws://127.0.0.1:8443)\n"
                  << "  --source <type>         Video source: libcamera, v4l2, test (default: libcamera)\n"
                  << "  --device <path>         V4L2 device path (default: /dev/video0)\n"
                  << "  --width <pixels>        Video width (default: 1280)\n"
                  << "  --height <pixels>       Video height (default: 720)\n"
                  << "  --fps <rate>            Framerate (default: 30)\n"
                  << "  --encoder <type>        Encoder: h264-hw, h264-sw, vp8, vp9 (default: h264-hw)\n"
                  << "  --bitrate <kbps>        Bitrate in kbps (default: 2000)\n"
                  << "\nExamples:\n"
                  << "  " << program << " --webrtc --config /path/to/webrtc_settings.json\n"
                  << "  " << program << " --webrtc --server ws://192.168.1.100:8443\n"
                  << "  " << program << " --webrtc --source v4l2 --device /dev/video0\n"
                  << "  " << program << " --webrtc --source test  # For testing without camera\n";
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
    mylib::MyCalculator calculator;
    
    // Parse arguments
    bool show_help = false;
    bool show_version = false;
    bool start_webrtc = false;
    std::string config_file_path;
    
    kataglyphis::webrtc::StreamConfig config;
    config.signalling_server_uri = "ws://127.0.0.1:8443";
    
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
            show_help = true;
        } else if (std::strcmp(argv[i], "--version") == 0 || std::strcmp(argv[i], "-v") == 0) {
            show_version = true;
        } else if (std::strcmp(argv[i], "--webrtc") == 0) {
            start_webrtc = true;
        } else if (std::strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_file_path = argv[++i];
        } else if (std::strcmp(argv[i], "--server") == 0 && i + 1 < argc) {
            config.signalling_server_uri = argv[++i];
        } else if (std::strcmp(argv[i], "--source") == 0 && i + 1 < argc) {
            ++i;
            if (std::strcmp(argv[i], "libcamera") == 0) {
                config.source = kataglyphis::webrtc::VideoSource::Libcamera;
            } else if (std::strcmp(argv[i], "v4l2") == 0) {
                config.source = kataglyphis::webrtc::VideoSource::V4L2;
            } else if (std::strcmp(argv[i], "test") == 0) {
                config.source = kataglyphis::webrtc::VideoSource::TestPattern;
            } else {
                std::cerr << "Unknown source: " << argv[i] << '\n';
                return 1;
            }
        } else if (std::strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            config.v4l2_device = argv[++i];
        } else if (std::strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            config.width = static_cast<std::uint32_t>(std::atoi(argv[++i]));
        } else if (std::strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            config.height = static_cast<std::uint32_t>(std::atoi(argv[++i]));
        } else if (std::strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            config.framerate = static_cast<std::uint32_t>(std::atoi(argv[++i]));
        } else if (std::strcmp(argv[i], "--encoder") == 0 && i + 1 < argc) {
            ++i;
            if (std::strcmp(argv[i], "h264-hw") == 0) {
                config.encoder = kataglyphis::webrtc::VideoEncoder::H264_Hardware;
            } else if (std::strcmp(argv[i], "h264-sw") == 0) {
                config.encoder = kataglyphis::webrtc::VideoEncoder::H264_Software;
            } else if (std::strcmp(argv[i], "vp8") == 0) {
                config.encoder = kataglyphis::webrtc::VideoEncoder::VP8;
            } else if (std::strcmp(argv[i], "vp9") == 0) {
                config.encoder = kataglyphis::webrtc::VideoEncoder::VP9;
            } else {
                std::cerr << "Unknown encoder: " << argv[i] << '\n';
                return 1;
            }
        } else if (std::strcmp(argv[i], "--bitrate") == 0 && i + 1 < argc) {
            config.bitrate_kbps = static_cast<std::uint32_t>(std::atoi(argv[++i]));
        }
    }
    
    if (show_help) {
        print_usage(argv[0]);
        return 0;
    }
    
    if (show_version) {
        std::cout << "KataglyphisCppInference " << calculator.version() << '\n';
        return 0;
    }
    
    if (!start_webrtc) {
        // Default behavior: show version
        std::cout << "KataglyphisCppInference " << calculator.version() << '\n';
        std::cout << "Use --help for usage information\n";
        return 0;
    }
    
    // Initialize WebRTC streaming
    std::cout << "Initializing WebRTC streaming...\n";
    
    auto init_result = kataglyphis::webrtc::WebRTCStreamer::initialize(&argc, &argv);
    if (!init_result) {
        std::cerr << "Failed to initialize GStreamer for WebRTC\n";
        return 1;
    }
    
    // Load configuration from JSON file if provided
    if (!config_file_path.empty()) {
        std::cout << "Loading configuration from: " << config_file_path << '\n';
        auto webrtc_config_result = kataglyphis::config::load_webrtc_config(config_file_path);
        if (webrtc_config_result) {
            const auto& webrtc_config = webrtc_config_result.value();
            // Apply JSON config values (CLI args will override these if specified)
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
    
    // Set up callbacks
    streamer.set_state_callback([](kataglyphis::webrtc::StreamState old_state, 
                                   kataglyphis::webrtc::StreamState new_state) -> void {
        std::cout << "State: " << state_to_string(old_state) 
                  << " -> " << state_to_string(new_state) << '\n';
    });
    
    streamer.set_error_callback([](kataglyphis::webrtc::WebRTCError /*error*/, 
                                   const std::string& message) -> void {
        std::cerr << "Error: " << message << '\n';
    });
    
    // Configure streamer
    auto configure_result = streamer.configure(config);
    if (!configure_result) {
        std::cerr << "Failed to configure WebRTC streamer\n";
        return 1;
    }
    
    std::cout << "Connecting to signalling server: " << config.signalling_server_uri << '\n';
    std::cout << "Producer ID: " << streamer.get_producer_id() << '\n';
    std::cout << "Resolution: " << config.width << "x" << config.height << "@" << config.framerate << "fps\n";
    
    // Start streaming
    auto start_result = streamer.start();
    if (!start_result) {
        std::cerr << "Failed to start WebRTC stream\n";
        return 1;
    }
    
    // Set up signal handler for graceful shutdown
    (void)std::signal(SIGINT, signal_handler);
    (void)std::signal(SIGTERM, signal_handler);
    
    std::cout << "Streaming... Press Ctrl+C to stop.\n";
    
    // Main loop - wait for signal
    while (g_running != 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        
        // Check if still streaming
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
