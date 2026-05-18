module;

#include "kataglyphis_export.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <expected>
#include <filesystem>
#include <gst/gst.h>
#include <gst/sdp/sdp.h>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

#define GST_USE_UNSTABLE_API
#include <gst/webrtc/webrtc.h>

module kataglyphis.webrtc_streamer;

import kataglyphis.project_config;
import kataglyphis.config_loader;

namespace kataglyphis::webrtc {

namespace {
    std::atomic<bool> g_gstreamer_initialized{ false };
    std::mutex g_gstreamer_mutex;

    auto error_to_string(WebRTCError error) -> const char *
    {
        switch (error) {
        case WebRTCError::InitializationFailed:
            return "GStreamer initialization failed";
        case WebRTCError::SignallingConnectionFailed:
            return "Failed to connect to signalling server";
        case WebRTCError::PipelineCreationFailed:
            return "Failed to create GStreamer pipeline";
        case WebRTCError::NegotiationFailed:
            return "WebRTC negotiation failed";
        case WebRTCError::MediaError:
            return "Media error";
        case WebRTCError::LibcameraNotAvailable:
            return "libcamera not available";
        case WebRTCError::EncoderNotAvailable:
            return "Video encoder not available";
        case WebRTCError::StateChangeFailed:
            return "Pipeline state change failed";
        case WebRTCError::InvalidConfiguration:
            return "Invalid configuration";
        case WebRTCError::Timeout:
            return "Operation timed out";
        }
        return "Unknown error";
    }

    auto make_default_producer_id() -> std::string
    {
        return "stream-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count() % 100000);
    }

    auto quote_pipeline_value(const std::string &value) -> std::string
    {
        std::string escaped;
        escaped.reserve(value.size() + 2);
        escaped.push_back('"');
        for (const char ch : value) {
            if (ch == '\\' || ch == '"') { escaped.push_back('\\'); }
            escaped.push_back(ch);
        }
        escaped.push_back('"');
        return escaped;
    }

    auto to_file_uri(const std::string &path) -> std::string
    {
        const auto absolute_path = std::filesystem::absolute(path);
        GError *error = nullptr;
        gchar *uri = gst_filename_to_uri(absolute_path.string().c_str(), &error);
        if (uri == nullptr) {
            if (error != nullptr) {
                g_printerr("Failed to convert file path to URI: %s\n", error->message);
                g_error_free(error);
            }
            return {};
        }

        std::string result{ uri };
        g_free(uri);
        return result;
    }

    auto parse_configured_source(const std::string &name, VideoSource fallback) -> VideoSource
    {
        if (name == "libcamera") { return VideoSource::Libcamera; }
        if (name == "v4l2") { return VideoSource::V4L2; }
        if (name == "test") { return VideoSource::TestPattern; }
        if (name == "file") { return VideoSource::File; }
        if (name == "uri") { return VideoSource::Uri; }
        return fallback;
    }

    auto parse_configured_encoder(const std::string &name, VideoEncoder fallback) -> VideoEncoder
    {
        if (name == "h264-hw") { return VideoEncoder::H264_Hardware; }
        if (name == "h264-sw") { return VideoEncoder::H264_Software; }
        if (name == "vp8") { return VideoEncoder::VP8; }
        if (name == "vp9") { return VideoEncoder::VP9; }
        return fallback;
    }

    auto create_configured_streamer(const StreamConfig& config) -> std::expected<WebRTCStreamer, WebRTCError>
    {
        auto init_result = WebRTCStreamer::initialize();
        if (!init_result) { return std::unexpected(init_result.error()); }

        WebRTCStreamer streamer;
        auto configure_result = streamer.configure(config);
        if (!configure_result) { return std::unexpected(configure_result.error()); }

        return streamer;
    }
}// namespace

struct WebRTCStreamer::Impl
{
    StreamConfig config;
    GstElement *pipeline{ nullptr };
    GstElement *webrtcsink{ nullptr };

    GMainLoop *main_loop{ nullptr };
    std::thread main_loop_thread;

    std::atomic<StreamState> state{ StreamState::Idle };
    StateCallback state_callback;
    ErrorCallback error_callback;
    std::string producer_id;

    std::mutex callback_mutex;

    ~Impl() { cleanup(); }

    void stop_main_loop()
    {
        if (main_loop != nullptr) {
            g_main_loop_quit(main_loop);
            if (main_loop_thread.joinable()) { main_loop_thread.join(); }
            g_main_loop_unref(main_loop);
            main_loop = nullptr;
        }
    }

    void destroy_pipeline()
    {
        if (webrtcsink != nullptr) {
            gst_object_unref(webrtcsink);
            webrtcsink = nullptr;
        }
        if (pipeline != nullptr) {
            gst_object_unref(pipeline);
            pipeline = nullptr;
        }
    }

    void cleanup()
    {
        stop_main_loop();
        if (pipeline != nullptr) { gst_element_set_state(pipeline, GST_STATE_NULL); }
        destroy_pipeline();
    }

    void set_state(StreamState new_state)
    {
        StreamState old_state = state.exchange(new_state);
        if (old_state != new_state) {
            std::scoped_lock lock(callback_mutex);
            if (state_callback) { state_callback(old_state, new_state); }
        }
    }

    void report_error(WebRTCError error, const std::string &message = "")
    {
        set_state(StreamState::Error);

        std::scoped_lock lock(callback_mutex);
        if (!error_callback) { return; }

        std::string full_message = error_to_string(error);
        if (!message.empty()) { full_message += ": " + message; }
        error_callback(error, full_message);
    }

    auto build_raw_video_caps() const -> std::string
    {
        std::ostringstream ss;
        ss << "video/x-raw,width=" << config.width << ",height=" << config.height
           << ",framerate=" << config.framerate << "/1";
        return ss.str();
    }

    auto build_source_element() const -> std::string
    {
        std::ostringstream ss;
        const auto raw_caps = build_raw_video_caps();

        switch (config.source) {
        case VideoSource::Libcamera:
            // libcamerasrc for Raspberry Pi cameras
            ss << "libcamerasrc";
            if (!config.camera_id.empty()) { ss << " camera-name=" << quote_pipeline_value(config.camera_id); }
            ss << " ! " << raw_caps;
            break;

        case VideoSource::V4L2:
            ss << "v4l2src device=" << quote_pipeline_value(config.v4l2_device) << " ! " << raw_caps;
            break;

        case VideoSource::TestPattern:
            ss << "videotestsrc is-live=true pattern=ball ! " << raw_caps;
            break;

        case VideoSource::File: {
            const auto uri = to_file_uri(config.input_path);
            if (uri.empty()) { return {}; }

            ss << "uridecodebin name=src uri=" << quote_pipeline_value(uri)
               << " src. ! queue ! videoconvert ! videoscale ! videorate ! " << raw_caps;
            break;
        }

        case VideoSource::Uri:
            ss << "uridecodebin name=src uri=" << quote_pipeline_value(config.input_uri)
               << " src. ! queue ! videoconvert ! videoscale ! videorate ! " << raw_caps;
            break;
        }

        return ss.str();
    }

    auto build_pipeline_description() -> std::string
    {
        std::ostringstream ss;

        // Source
        ss << build_source_element();

        // Video conversion for compatibility
        ss << " ! videoconvert";

        // webrtcsink handles encoding, payloading, and signalling automatically
        ss << " ! webrtcsink name=ws";

        // Configure signalling server URI
        ss << " signaller::uri=" << quote_pipeline_value(config.signalling_server_uri);

        // Set up video encoding based on encoder preference
        switch (config.encoder) {
        case VideoEncoder::H264_Hardware:
        case VideoEncoder::H264_Software:
            ss << " video-caps=\"video/x-h264\"";
            break;
        case VideoEncoder::VP8:
            ss << " video-caps=\"video/x-vp8\"";
            break;
        case VideoEncoder::VP9:
            ss << " video-caps=\"video/x-vp9\"";
            break;
        }

        // Add STUN server
        if (!config.stun_servers.empty()) {
            ss << " stun-server=" << quote_pipeline_value(config.stun_servers[0]);
        } else {
            ss << " stun-server=" << quote_pipeline_value("stun://stun.l.google.com:19302");
        }

        return ss.str();
    }

    // Callback for when pipeline encounters an error
    static auto on_bus_error(GstBus * /* bus */, GstMessage *msg, gpointer user_data) -> gboolean
    {
        auto *impl = static_cast<Impl *>(user_data);

        GError *error = nullptr;
        gchar *debug_info = nullptr;
        gst_message_parse_error(msg, &error, &debug_info);

        std::string error_message = (error != nullptr) ? error->message : "Unknown error";
        if (debug_info != nullptr) { error_message += " (" + std::string(debug_info) + ")"; }

        g_printerr("Pipeline error: %s\n", error_message.c_str());
        impl->report_error(WebRTCError::MediaError, error_message);

        if (error != nullptr) { g_error_free(error);
}
        if (debug_info != nullptr) { g_free(debug_info);
}

        return TRUE;
    }

    // Callback for state changes
    static auto on_bus_state_changed(GstBus * /* bus */, GstMessage *msg, gpointer user_data) -> gboolean
    {
        auto *impl = static_cast<Impl *>(user_data);

        if (GST_MESSAGE_SRC(msg) != GST_OBJECT(impl->pipeline)) { return TRUE; }

GstState old_state;
        GstState new_state;
        gst_message_parse_state_changed(msg, &old_state, &new_state, nullptr);

        g_print(
          "Pipeline state: %s -> %s\n", gst_element_state_get_name(old_state), gst_element_state_get_name(new_state));

        if (new_state == GST_STATE_PLAYING) {
            impl->set_state(StreamState::Streaming);
        } else if (new_state == GST_STATE_PAUSED && impl->state.load() == StreamState::Streaming) {
            impl->set_state(StreamState::Paused);
        }

        return TRUE;
    }

    // Callback for EOS
    static auto on_bus_eos(GstBus * /* bus */, GstMessage * /* msg */, gpointer user_data) -> gboolean
    {
        auto *impl = static_cast<Impl *>(user_data);
        g_print("End of stream\n");
        impl->set_state(StreamState::Disconnected);
        return TRUE;
    }

    // Callback for element messages (webrtcsink status updates)
    static auto on_bus_element(GstBus * /* bus */, GstMessage *msg, gpointer user_data) -> gboolean
    {
        auto *impl = static_cast<Impl *>(user_data);

        const GstStructure *structure = gst_message_get_structure(msg);
        if (structure == nullptr) { return TRUE;
}

        const gchar *name = gst_structure_get_name(structure);
        if (g_str_has_prefix(name, "webrtcsink") != 0) {
            g_print("WebRTC event: %s\n", name);

            // Check for connection established
            if (g_str_has_suffix(name, "consumer-added") != 0) {
                g_print("WebRTC peer connected!\n");
                impl->set_state(StreamState::Streaming);
            } else if (g_str_has_suffix(name, "consumer-removed") != 0) {
                g_print("WebRTC peer disconnected\n");
            }
        }

        return TRUE;
    }
};

WebRTCStreamer::WebRTCStreamer() : impl_(std::make_unique<Impl>()) {}

WebRTCStreamer::~WebRTCStreamer() = default;

WebRTCStreamer::WebRTCStreamer(WebRTCStreamer &&) noexcept = default;

auto WebRTCStreamer::operator=(WebRTCStreamer &&) noexcept -> WebRTCStreamer & = default;

auto WebRTCStreamer::initialize(int *argc, char ***argv) -> std::expected<void, WebRTCError>
{
    std::scoped_lock lock(g_gstreamer_mutex);

    if (g_gstreamer_initialized.load()) { return {}; }

    GError *error = nullptr;
    if (gst_init_check(argc, argv, &error) == 0) {
        if (error != nullptr) {
            g_printerr("GStreamer init failed: %s\n", error->message);
            g_error_free(error);
        }
        return std::unexpected(WebRTCError::InitializationFailed);
    }

    // Verify webrtcsink is available
    GstElementFactory *factory = gst_element_factory_find("webrtcsink");
    if (factory == nullptr) {
        g_printerr("webrtcsink element not found. Checking for webrtcbin fallback...\n");

        // Fall back to webrtcbin if webrtcsink is not available
        factory = gst_element_factory_find("webrtcbin");
        if (factory == nullptr) {
            g_printerr("Neither webrtcsink nor webrtcbin found!\n");
            gst_deinit();
            return std::unexpected(WebRTCError::InitializationFailed);
        }
        g_print("Using webrtcbin (manual signalling required)\n");
    } else {
        g_print("Using webrtcsink (automatic signalling)\n");
    }
    gst_object_unref(factory);

    g_gstreamer_initialized.store(true);
    return {};
}

auto WebRTCStreamer::deinitialize() -> void
{
    std::scoped_lock lock(g_gstreamer_mutex);
    if (g_gstreamer_initialized.load()) {
        gst_deinit();
        g_gstreamer_initialized.store(false);
    }
}

auto WebRTCStreamer::configure(const StreamConfig &config) -> std::expected<void, WebRTCError>
{
    if (!g_gstreamer_initialized.load()) { return std::unexpected(WebRTCError::InitializationFailed); }

    // Validate configuration
    if (config.width == 0 || config.height == 0 || config.framerate == 0) {
        return std::unexpected(WebRTCError::InvalidConfiguration);
    }

    if (config.signalling_server_uri.empty()) { return std::unexpected(WebRTCError::InvalidConfiguration); }
    if (config.source == VideoSource::V4L2 && config.v4l2_device.empty()) {
        return std::unexpected(WebRTCError::InvalidConfiguration);
    }
    if (config.source == VideoSource::File && config.input_path.empty()) {
        return std::unexpected(WebRTCError::InvalidConfiguration);
    }
    if (config.source == VideoSource::Uri && config.input_uri.empty()) {
        return std::unexpected(WebRTCError::InvalidConfiguration);
    }

    impl_->cleanup();
    impl_->config = config;
    impl_->set_state(StreamState::Idle);

    // Generate producer ID if not specified
    if (config.producer_id.empty()) {
        impl_->producer_id = make_default_producer_id();
    } else {
        impl_->producer_id = config.producer_id;
    }

    // Build pipeline
    std::string pipeline_desc = impl_->build_pipeline_description();
    g_print("Pipeline: %s\n", pipeline_desc.c_str());

    GError *error = nullptr;
    impl_->pipeline = gst_parse_launch(pipeline_desc.c_str(), &error);

    if (error != nullptr) {
        std::string error_msg = error->message;
        g_printerr("Pipeline creation failed: %s\n", error_msg.c_str());
        g_error_free(error);
        return std::unexpected(WebRTCError::PipelineCreationFailed);
    }

    if (impl_->pipeline == nullptr) { return std::unexpected(WebRTCError::PipelineCreationFailed); }

    // Get webrtcsink element
    impl_->webrtcsink = gst_bin_get_by_name(GST_BIN(impl_->pipeline), "ws");
    if (impl_->webrtcsink != nullptr) { g_print("Found webrtcsink element\n"); }

    // Set up bus watches
    GstBus *bus = gst_element_get_bus(impl_->pipeline);
    gst_bus_add_signal_watch(bus);
    g_signal_connect(bus, "message::error", G_CALLBACK(Impl::on_bus_error), impl_.get());
    g_signal_connect(bus, "message::state-changed", G_CALLBACK(Impl::on_bus_state_changed), impl_.get());
    g_signal_connect(bus, "message::eos", G_CALLBACK(Impl::on_bus_eos), impl_.get());
    g_signal_connect(bus, "message::element", G_CALLBACK(Impl::on_bus_element), impl_.get());
    gst_object_unref(bus);

    return {};
}

auto WebRTCStreamer::start() -> std::expected<void, WebRTCError>
{
    if (impl_->pipeline == nullptr) { return std::unexpected(WebRTCError::PipelineCreationFailed); }

    impl_->set_state(StreamState::Connecting);

    // Start main loop in background thread for GLib callbacks
    impl_->main_loop = g_main_loop_new(nullptr, FALSE);
    impl_->main_loop_thread = std::thread([this]() -> void { g_main_loop_run(impl_->main_loop); });

    // Start the pipeline
    g_print("Starting pipeline...\n");
    g_print("Connecting to signalling server: %s\n", impl_->config.signalling_server_uri.c_str());

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) {
        g_printerr("Failed to start pipeline\n");
        impl_->set_state(StreamState::Error);
        return std::unexpected(WebRTCError::StateChangeFailed);
    }

    // Wait for pipeline to reach PLAYING state (with timeout)
    GstState state;
    ret = gst_element_get_state(impl_->pipeline, &state, nullptr, 10 * GST_SECOND);

    if (ret == GST_STATE_CHANGE_FAILURE) {
        impl_->set_state(StreamState::Error);
        return std::unexpected(WebRTCError::StateChangeFailed);
    }

    g_print("Pipeline started, waiting for peers to connect...\n");

    return {};
}

auto WebRTCStreamer::stop() -> std::expected<void, WebRTCError>
{
    if (impl_->pipeline == nullptr) { return {}; }

    g_print("Stopping pipeline...\n");

    // Send EOS to gracefully stop
    gst_element_send_event(impl_->pipeline, gst_event_new_eos());

    // Wait briefly for EOS to propagate
    GstBus *bus = gst_element_get_bus(impl_->pipeline);
    (void)gst_bus_timed_pop_filtered(bus, GST_SECOND, GST_MESSAGE_EOS);
    gst_object_unref(bus);

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_NULL);

    // Stop main loop and join thread before pipeline cleanup
    impl_->stop_main_loop();

    // Pipeline refs are now safe to release (no callbacks running)
    impl_->destroy_pipeline();

    impl_->set_state(StreamState::Idle);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(WebRTCError::StateChangeFailed); }

    return {};
}

auto WebRTCStreamer::pause() -> std::expected<void, WebRTCError>
{
    if (impl_->pipeline == nullptr) { return std::unexpected(WebRTCError::PipelineCreationFailed); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PAUSED);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(WebRTCError::StateChangeFailed); }

    impl_->set_state(StreamState::Paused);
    return {};
}

auto WebRTCStreamer::resume() -> std::expected<void, WebRTCError>
{
    if (impl_->pipeline == nullptr) { return std::unexpected(WebRTCError::PipelineCreationFailed); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(WebRTCError::StateChangeFailed); }

    return {};
}

auto WebRTCStreamer::get_state() const -> StreamState { return impl_->state.load(); }

auto WebRTCStreamer::is_streaming() const -> bool { return impl_->state.load() == StreamState::Streaming; }

auto WebRTCStreamer::get_producer_id() const -> std::string { return impl_->producer_id; }

auto WebRTCStreamer::set_state_callback(StateCallback callback) -> void
{
    std::scoped_lock lock(impl_->callback_mutex);
    impl_->state_callback = std::move(callback);
}

auto WebRTCStreamer::set_error_callback(ErrorCallback callback) -> void
{
    std::scoped_lock lock(impl_->callback_mutex);
    impl_->error_callback = std::move(callback);
}

auto WebRTCStreamer::set_bitrate(std::uint32_t bitrate_kbps) -> std::expected<void, WebRTCError>
{
    impl_->config.bitrate_kbps = bitrate_kbps;
    // NOTE: This only stores the config value. Runtime bitrate changes require
    // accessing the encoder element via gst_bin_get_by_name() and setting the
    // "bitrate" property while the pipeline is in PLAYING state.
    return {};
}

// Factory functions

auto create_libcamera_webrtc_stream(const std::string &signalling_server,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<WebRTCStreamer, WebRTCError>
{
    StreamConfig config;
    config.source = VideoSource::Libcamera;
    config.encoder = VideoEncoder::H264_Hardware;
    config.signalling_server_uri = signalling_server;
    config.width = width;
    config.height = height;
    config.framerate = fps;

    return create_configured_streamer(std::move(config));
}

auto create_v4l2_webrtc_stream(const std::string &signalling_server,
  const std::string &device,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<WebRTCStreamer, WebRTCError>
{
    StreamConfig config;
    config.source = VideoSource::V4L2;
    config.encoder = VideoEncoder::H264_Hardware;
    config.signalling_server_uri = signalling_server;
    config.v4l2_device = device;
    config.width = width;
    config.height = height;
    config.framerate = fps;

    return create_configured_streamer(std::move(config));
}

auto create_test_webrtc_stream(const std::string &signalling_server) -> std::expected<WebRTCStreamer, WebRTCError>
{
    StreamConfig config;
    config.source = VideoSource::TestPattern;
    config.encoder = VideoEncoder::H264_Software;
    config.signalling_server_uri = signalling_server;
    config.width = 1280;
    config.height = 720;
    config.framerate = 30;

    return create_configured_streamer(std::move(config));
}

// Helper to create StreamConfig from WebRTCConfig
auto create_stream_config_from_webrtc_config(const config::WebRTCConfig &webrtc_config,
  VideoSource source,
  VideoEncoder encoder,
  ConfigOverrideMode source_override_mode,
  ConfigOverrideMode encoder_override_mode) -> StreamConfig
{
    StreamConfig config;

    config.source = source_override_mode == ConfigOverrideMode::Override
                      ? source
                      : parse_configured_source(webrtc_config.stream.source, source);
    config.encoder = encoder_override_mode == ConfigOverrideMode::Override
                       ? encoder
                       : parse_configured_encoder(webrtc_config.stream.encoder, encoder);
    config.signalling_server_uri = webrtc_config.signaling_server_url;
    config.width = webrtc_config.video.default_width;
    config.height = webrtc_config.video.default_height;
    config.framerate = webrtc_config.video.default_framerate;
    config.bitrate_kbps = webrtc_config.video.default_bitrate_kbps;
    config.camera_id = webrtc_config.stream.camera_id;
    config.v4l2_device = webrtc_config.stream.device;
    config.input_path = webrtc_config.stream.input_path;
    config.input_uri = webrtc_config.stream.input_uri;
    config.peer_id = webrtc_config.stream.peer_id;
    config.producer_id = webrtc_config.stream.producer_id;
    config.stun_servers = webrtc_config.stun_servers;
    config.turn_servers = webrtc_config.turn_servers;

    return config;
}

// Factory function that loads config from JSON file
auto create_webrtc_stream_from_config(const std::filesystem::path &config_path,
  VideoSource source,
  VideoEncoder encoder,
  ConfigOverrideMode source_override_mode,
  ConfigOverrideMode encoder_override_mode) -> std::expected<WebRTCStreamer, WebRTCError>
{
    auto webrtc_config = config::get_default_webrtc_config();
    if (auto config_result = config::load_webrtc_config(config_path); config_result) {
        webrtc_config = *config_result;
    } else {
        g_printerr("Failed to load config from %s, using defaults\n", config_path.string().c_str());
    }

    return create_configured_streamer(create_stream_config_from_webrtc_config(
      webrtc_config, source, encoder, source_override_mode, encoder_override_mode));
}

}// namespace kataglyphis::webrtc
