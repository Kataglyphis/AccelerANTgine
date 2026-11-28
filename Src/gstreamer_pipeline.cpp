module;

#include "kataglyphis_export.h"
#include <atomic>
#include <cstddef>
#include <expected>
#include <gst/analytics/analytics.h>
#include <gst/analytics/gsttensor.h>
#include <gst/analytics/gsttensormeta.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <vector>

module kataglyphis.gstreamer_pipeline;

import kataglyphis.project_config;
import kataglyphis.log;
import kataglyphis.gstreamer_runtime;

namespace kataglyphis::gstreamer {

namespace {
    auto parse_pipeline_description(const std::string &pipeline_description, const char *failure_context)
      -> std::expected<GstElement *, GStreamerError>
    {
        GstElement *pipeline = runtime::parse_launch(pipeline_description, failure_context);
        if (pipeline == nullptr) { return std::unexpected(GStreamerError::PipelineCreationFailed); }
        return pipeline;
    }

    // The first element of the given type in the pipeline (or the pipeline itself), with a reference the caller owns.
    auto find_element_of_type(GstElement *root, GType type) -> GstElement *
    {
        if (G_TYPE_CHECK_INSTANCE_TYPE(root, type)) { return GST_ELEMENT(gst_object_ref(root)); }
        if (!GST_IS_BIN(root)) { return nullptr; }

        // find_custom restarts the walk itself when the bin changes under it (a resync).
        GstIterator *iterator = gst_bin_iterate_recurse(GST_BIN(root));
        GValue item = G_VALUE_INIT;
        GstElement *found = nullptr;
        // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): GLib's GCompareFunc fixes the two pointers.
        const auto of_type = [](gconstpointer value, gconstpointer wanted) -> gint {
            auto *element = g_value_get_object(static_cast<const GValue *>(value));
            return G_TYPE_CHECK_INSTANCE_TYPE(element, *static_cast<const GType *>(wanted)) ? 0 : 1;
        };
        if (gst_iterator_find_custom(iterator, of_type, &item, &type) != 0) {
            found = GST_ELEMENT(g_value_dup_object(&item));
            g_value_unset(&item);
        }
        gst_iterator_free(iterator);
        return found;
    }

    void append_tensor_metadata(GstBuffer *buffer, BufferInfo &buffer_info)
    {
        if (auto *meta = gst_buffer_get_tensor_meta(buffer)) {
            buffer_info.tensors.reserve(meta->num_tensors);
            for (gsize i = 0; i < meta->num_tensors; ++i) {
                const GstTensor *tensor = gst_tensor_meta_get(meta, i);
                TensorMeta tensor_meta;
                tensor_meta.tensor_index = i;
                tensor_meta.num_tensors = meta->num_tensors;
                tensor_meta.data_type = static_cast<int>(tensor->data_type);

                gsize num_dims = 0;
                auto *dims = gst_tensor_get_dims(const_cast<GstTensor *>(tensor), &num_dims);
                tensor_meta.dimensions.reserve(num_dims);
                for (gsize j = 0; j < num_dims; ++j) { tensor_meta.dimensions.push_back(dims[j]); }
                buffer_info.tensors.push_back(std::move(tensor_meta));
            }
        }
    }

    void append_frame_metadata(GstCaps *caps, GstBuffer *buffer, BufferInfo &buffer_info)
    {
        if (caps != nullptr) {
            GstStructure *structure = gst_caps_get_structure(caps, 0);
            if (structure != nullptr) {
                // Raw video caps carry width and height as G_TYPE_INT, which gst_structure_get_uint never matches.
                gint width = 0;
                gint height = 0;
                if (gst_structure_get_int(structure, "width", &width) != 0 && width > 0) {
                    buffer_info.metadata.width = static_cast<std::uint32_t>(width);
                }
                if (gst_structure_get_int(structure, "height", &height) != 0 && height > 0) {
                    buffer_info.metadata.height = static_cast<std::uint32_t>(height);
                }

                gint fps_n = 0;
                gint fps_d = 0;
                if (gst_structure_get_fraction(structure, "framerate", &fps_n, &fps_d) != 0 && fps_n >= 0
                    && fps_d > 0) {
                    buffer_info.metadata.fps_n = static_cast<std::uint32_t>(fps_n);
                    buffer_info.metadata.fps_d = static_cast<std::uint32_t>(fps_d);
                }

                const gchar *format = gst_structure_get_string(structure, "format");
                if (format != nullptr) { buffer_info.metadata.format = format; }
                GstVideoInfo video_info;
                if (gst_video_info_from_caps(&video_info, caps) != 0 && GST_VIDEO_INFO_N_PLANES(&video_info) == 1) {
                    buffer_info.metadata.row_stride_bytes = GST_VIDEO_INFO_PLANE_STRIDE(&video_info, 0);
                    buffer_info.metadata.plane_offset_bytes = GST_VIDEO_INFO_PLANE_OFFSET(&video_info, 0);
                }
            }
        }

        buffer_info.metadata.timestamp_ns = GST_BUFFER_PTS(buffer);
        buffer_info.metadata.duration_ns = GST_BUFFER_DURATION(buffer);
        if (const auto *video_meta = gst_buffer_get_video_meta(buffer);
          video_meta != nullptr && video_meta->n_planes == 1) {
            buffer_info.metadata.row_stride_bytes = video_meta->stride[0];
            buffer_info.metadata.plane_offset_bytes = video_meta->offset[0];
        }
    }

    auto extract_buffer_info(GstSample *sample) -> std::expected<BufferInfo, GStreamerError>
    {
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        if (buffer == nullptr) { return std::unexpected(GStreamerError::BufferAllocationFailed); }

        GstMapInfo map_info;
        if (gst_buffer_map(buffer, &map_info, GST_MAP_READ) == 0) {
            return std::unexpected(GStreamerError::BufferAllocationFailed);
        }

        BufferInfo buffer_info;
        buffer_info.size = map_info.size;
        // assign, not resize and memcpy: resize zero-fills 2.7 MB at 720p that the copy overwrites at once.
        const auto mapped = std::as_bytes(std::span(map_info.data, map_info.size));
        buffer_info.data.assign(mapped.begin(), mapped.end());

        append_tensor_metadata(buffer, buffer_info);
        append_frame_metadata(gst_sample_get_caps(sample), buffer, buffer_info);

        gst_buffer_unmap(buffer, &map_info);
        return buffer_info;
    }
}// namespace

struct GStreamerPipeline::Impl
{
    GstElement *pipeline{ nullptr };
    GstElement *appsink{ nullptr };

    BufferCallback buffer_callback;
    // Recursive, each frame on a copy: the callback may call set_buffer_callback without relocking or freeing itself.
    std::recursive_mutex callback_mutex;
    std::atomic<bool> is_playing{ false };
    std::atomic<bool> is_paused{ false };
    // How the stream stands, written by the bus, the streaming thread and request_stop(), read from any thread.
    struct Stream
    {
        std::atomic<bool> ended{ false };
        std::atomic<bool> failed{ false };
        std::atomic<bool> stop_requested{ false };
        // The thread inside the buffer callback, so stop() refuses there instead of waiting for itself.
        std::atomic<std::thread::id> callback_thread;
    } stream;
    std::mutex error_mutex;
    std::string stream_error;

    GMainLoop *main_loop{ nullptr };
    std::thread main_loop_thread;
    bool callbacks_installed{ false };

    ~Impl() { cleanup(); }

    void cleanup()
    {
        if (main_loop != nullptr) {
            g_main_loop_quit(main_loop);
            if (main_loop_thread.joinable()) { main_loop_thread.join(); }
            g_main_loop_unref(main_loop);
            main_loop = nullptr;
        }
        if (pipeline != nullptr) {
            gst_element_set_state(pipeline, GST_STATE_NULL);
            wait_for_callbacks();
            set_bus_handler(nullptr);
        }
        forget_stream_end();
        // Both hold their own reference, so the pipeline below is only freed once they let go.
        if (appsink != nullptr) {
            if (callbacks_installed) {
                GstAppSinkCallbacks none{};
                gst_app_sink_set_callbacks(GST_APP_SINK(appsink), &none, nullptr, nullptr);
            }
            gst_object_unref(appsink);
            appsink = nullptr;
        }
        callbacks_installed = false;
        if (pipeline != nullptr) {
            runtime::release(pipeline);
            pipeline = nullptr;
        }
        is_playing.store(false);
        is_paused.store(false);
    }

    // No callback runs after the NULL state change; the lock makes that ordering visible to TSan as well.
    void wait_for_callbacks() { std::scoped_lock lock(callback_mutex); }

    // Nothing else reads the bus: without a handler an error upstream is invisible, and every message stays queued.
    void set_bus_handler(GstBusSyncHandler handler)
    {
        GstBus *bus = gst_element_get_bus(pipeline);
        gst_bus_set_sync_handler(bus, handler, handler != nullptr ? this : nullptr, nullptr);
        gst_object_unref(bus);
    }

    void forget_stream_end()
    {
        std::scoped_lock lock(error_mutex);
        stream_error.clear();
        stream.failed.store(false);
        stream.ended.store(false);
        stream.stop_requested.store(false);
    }

    // stop() and the create calls from inside the callback would set NULL on the streaming thread that runs it.
    [[nodiscard]] auto refuse_from_callback(const char *what) const -> bool
    {
        if (stream.callback_thread.load() != std::this_thread::get_id()) { return false; }
        log::error("GStreamerPipeline::{} called from its own buffer callback; call request_stop() there", what);
        return true;
    }

    static auto on_bus_message([[maybe_unused]] GstBus *bus, GstMessage *message, gpointer user_data) -> GstBusSyncReply
    {
        auto *self = static_cast<Impl *>(user_data);
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) {
            self->stream.ended.store(true);
        } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
            GError *error = nullptr;
            gst_message_parse_error(message, &error, nullptr);
            {
                std::scoped_lock lock(self->error_mutex);
                // The first error names the cause; the elements around it only report that the stream broke.
                if (!self->stream.failed.load()) {
                    const GstObject *source = GST_MESSAGE_SRC(message);
                    self->stream_error = source != nullptr ? std::string(GST_OBJECT_NAME(source)) + ": " : "";
                    self->stream_error += error != nullptr ? error->message : "unknown error";
                }
                self->stream.failed.store(true);
            }
            g_clear_error(&error);
        }
        gst_message_unref(message);
        return GST_BUS_DROP;
    }

    // The C API, not the appsink signals, which delivered nothing on Windows (run 36902874261).
    void connect_buffer_callback()
    {
        if (appsink == nullptr || callbacks_installed) { return; }
        {
            std::scoped_lock lock(callback_mutex);
            if (!buffer_callback) { return; }
        }
        GstAppSinkCallbacks callbacks{};
        callbacks.new_sample = &Impl::on_new_sample;
        gst_app_sink_set_callbacks(GST_APP_SINK(appsink), &callbacks, this, nullptr);
        callbacks_installed = true;
    }

    // appsink stops the stream on anything but GST_FLOW_OK.
    static auto on_new_sample(GstAppSink *sink, gpointer user_data) -> GstFlowReturn
    {
        auto *self = static_cast<Impl *>(user_data);
        // EOS upstream: the source sends its end, the bus reports it, and has_ended() turns true.
        if (self->stream.stop_requested.load()) { return GST_FLOW_EOS; }
        // A concurrent pull_sample may have taken it; a blocking pull here would stall the streaming thread and stop().
        GstSample *sample = gst_app_sink_try_pull_sample(sink, 0);

        if (sample != nullptr) {
            auto buffer_info = extract_buffer_info(sample);
            if (buffer_info) {
                std::scoped_lock lock(self->callback_mutex);
                if (const BufferCallback callback = self->buffer_callback; callback) {
                    self->stream.callback_thread.store(std::this_thread::get_id());
                    callback(*buffer_info);
                    self->stream.callback_thread.store(std::thread::id{});
                }
            }
            gst_sample_unref(sample);
        }
        return self->stream.stop_requested.load() ? GST_FLOW_EOS : GST_FLOW_OK;
    }

    static auto on_pad_probe([[maybe_unused]] GstPad *pad,
      [[maybe_unused]] GstPadProbeInfo *info,
      [[maybe_unused]] gpointer user_data) -> GstPadProbeReturn
    { return GST_PAD_PROBE_OK; }
};

GStreamerPipeline::GStreamerPipeline() : impl_(std::make_unique<Impl>()) {}

GStreamerPipeline::~GStreamerPipeline() = default;

GStreamerPipeline::GStreamerPipeline(GStreamerPipeline &&) noexcept = default;

auto GStreamerPipeline::operator=(GStreamerPipeline &&) noexcept -> GStreamerPipeline & = default;

auto GStreamerPipeline::initialize_gstreamer(int *argc, char ***argv) -> std::expected<void, GStreamerError>
{
    if (!runtime::initialize(argc, argv)) { return std::unexpected(GStreamerError::InitializationFailed); }
    return {};
}

auto GStreamerPipeline::deinitialize_gstreamer() -> bool { return runtime::deinitialize(); }

auto GStreamerPipeline::create_pipeline(const PipelineConfig &config) -> std::expected<void, GStreamerError>
{

    if (!runtime::is_initialized()) { return std::unexpected(GStreamerError::InitializationFailed); }
    if (impl_->refuse_from_callback("create_pipeline")) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->cleanup();

    auto pipeline = parse_pipeline_description(config.pipeline_description, "Pipeline creation failed");
    if (!pipeline) { return std::unexpected(pipeline.error()); }
    impl_->pipeline = *pipeline;
    impl_->set_bus_handler(&Impl::on_bus_message);

    // Without it pull_sample and the buffer callback have nothing to talk to.
    impl_->appsink = find_element_of_type(impl_->pipeline, GST_TYPE_APP_SINK);
    impl_->connect_buffer_callback();

    return {};
}

auto GStreamerPipeline::create_pipeline_from_string(const std::string &description)
  -> std::expected<void, GStreamerError>
{
    PipelineConfig config;
    config.pipeline_description = description;
    return create_pipeline(config);
}

auto GStreamerPipeline::create_inference_pipeline(const std::string &input_source,
  const std::string &model_path,
  const std::vector<std::size_t> & /*input_shape*/,
  const std::string &output_format) -> std::expected<void, GStreamerError>
{

    if (!runtime::is_initialized()) { return std::unexpected(GStreamerError::InitializationFailed); }
    if (impl_->refuse_from_callback("create_inference_pipeline")) {
        return std::unexpected(GStreamerError::StateChangeFailed);
    }

    impl_->cleanup();

    auto pipeline = parse_pipeline_description(
      inference_pipeline_description(input_source, model_path, output_format), "Inference pipeline creation failed");
    if (!pipeline) { return std::unexpected(pipeline.error()); }
    impl_->pipeline = *pipeline;
    impl_->set_bus_handler(&Impl::on_bus_message);

    impl_->appsink = gst_bin_get_by_name(GST_BIN(impl_->pipeline), "sink");
    if (impl_->appsink == nullptr) { return std::unexpected(GStreamerError::ElementCreationFailed); }

    g_object_set(impl_->appsink, "emit-signals", TRUE, nullptr);
    impl_->connect_buffer_callback();

    return {};
}

auto GStreamerPipeline::start() -> std::expected<void, GStreamerError>
{
    if (impl_->pipeline == nullptr) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    // A resume keeps what the running stream reported; a new run starts without the last one's end.
    if (!impl_->is_playing.load()) { impl_->forget_stream_end(); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->is_playing.store(true);
    impl_->is_paused.store(false);
    return {};
}

auto GStreamerPipeline::stop() -> std::expected<void, GStreamerError>
{
    if (impl_->pipeline == nullptr) { return {}; }
    if (impl_->refuse_from_callback("stop")) { return std::unexpected(GStreamerError::StateChangeFailed); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_NULL);
    impl_->wait_for_callbacks();

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->is_playing.store(false);
    impl_->is_paused.store(false);
    return {};
}

auto GStreamerPipeline::pause() -> std::expected<void, GStreamerError>
{
    if (impl_->pipeline == nullptr) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PAUSED);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->is_paused.store(true);
    return {};
}

auto GStreamerPipeline::request_stop() -> void { impl_->stream.stop_requested.store(true); }

auto GStreamerPipeline::is_playing() const -> bool { return impl_->is_playing.load() && !impl_->is_paused.load(); }

auto GStreamerPipeline::has_ended() const -> bool { return impl_->stream.ended.load() || impl_->stream.failed.load(); }

auto GStreamerPipeline::stream_error() const -> std::optional<std::string>
{
    std::scoped_lock lock(impl_->error_mutex);
    if (!impl_->stream.failed.load()) { return std::nullopt; }
    return impl_->stream_error;
}

auto GStreamerPipeline::set_buffer_callback(BufferCallback callback) -> void
{
    {
        std::scoped_lock lock(impl_->callback_mutex);
        impl_->buffer_callback = std::move(callback);
    }

    impl_->connect_buffer_callback();
}

auto GStreamerPipeline::pull_sample(std::uint32_t timeout_ms) -> std::expected<BufferInfo, GStreamerError>
{

    if (impl_->appsink == nullptr) { return std::unexpected(GStreamerError::ElementCreationFailed); }

    GstSample *sample = nullptr;

    if (timeout_ms == 0) {
        sample = gst_app_sink_pull_sample(GST_APP_SINK(impl_->appsink));
    } else {
        GstClockTime timeout = static_cast<GstClockTime>(timeout_ms) * GST_MSECOND;
        sample = gst_app_sink_try_pull_sample(GST_APP_SINK(impl_->appsink), timeout);
    }

    // A failed stream is not a frame that is late: the caller of a camera has to tell the two apart.
    if (sample == nullptr) {
        // Asked here too: the caller reads has_ended() right after this pull. A sink that never played says EOS as well.
        if (impl_->is_playing.load() && gst_app_sink_is_eos(GST_APP_SINK(impl_->appsink)) != FALSE) {
            impl_->stream.ended.store(true);
        }
        return std::unexpected(
          impl_->stream.failed.load() ? GStreamerError::StreamError : GStreamerError::BufferAllocationFailed);
    }

    auto buffer_info = extract_buffer_info(sample);
    gst_sample_unref(sample);
    return buffer_info;
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

auto inference_pipeline_description(const std::string &input_source,
  const std::string &model_path,
  const std::string &output_format) -> std::string
{
    std::string pipeline_desc;

    if (input_source.contains("://")) {
        pipeline_desc = "uridecodebin uri=" + quote_pipeline_value(input_source) + " ! ";
    } else if (input_source.starts_with("/dev/video")) {
        pipeline_desc = "v4l2src device=" + quote_pipeline_value(input_source) + " ! ";
    } else {
        pipeline_desc = "filesrc location=" + quote_pipeline_value(input_source) + " ! decodebin ! ";
    }

    pipeline_desc +=
      "videoconvert ! videoscale ! "
      "video/x-raw,format=RGB,width=640,height=480 ! "
      "tensor_transform mode=transpose option=1:2:0:3 ! "
      "tensor_transform mode=typecast option=float32 ! "
      "onnxruntime model-path="
      + quote_pipeline_value(model_path);

    if (output_format == "TENSOR") { pipeline_desc += " ! tensor_decoder mode=direct"; }

    pipeline_desc += " ! appsink name=sink emit-signals=true";
    return pipeline_desc;
}

auto video_inference_pipeline_description(const std::string &video_source,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  const std::string &output_sink) -> std::string
{
    std::string pipeline_desc;

    if (video_source.contains("://")) {
        pipeline_desc = "uridecodebin uri=" + quote_pipeline_value(video_source) + " ! ";
    } else {
        pipeline_desc = "filesrc location=" + quote_pipeline_value(video_source) + " ! decodebin ! ";
    }

    pipeline_desc += "videoconvert ! videoscale ! "
                     "video/x-raw,format=RGB,width="
                     + std::to_string(width) + ",height=" + std::to_string(height)
                     + " ! "
                       "tensor_transform mode=transpose option=1:2:0:3 ! "
                       "tensor_transform mode=typecast option=float32 ! "
                       "onnxruntime model-path="
                     + quote_pipeline_value(model_path);

    if (output_sink == "appsink") {
        pipeline_desc += " ! appsink name=sink emit-signals=true sync=false";
    } else if (output_sink == "fakesink") {
        pipeline_desc += " ! fakesink sync=false";
    }
    return pipeline_desc;
}

auto camera_inference_pipeline_description(const std::string &device,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::string
{
    return "v4l2src device=" + quote_pipeline_value(device) + " ! "
           "video/x-raw,width="
           + std::to_string(width) + ",height=" + std::to_string(height) + ",framerate=" + std::to_string(fps)
           + "/1 ! "
             "videoconvert ! "
             "tensor_transform mode=transpose option=1:2:0:3 ! "
             "tensor_transform mode=typecast option=float32 ! "
             "onnxruntime model-path="
           + quote_pipeline_value(model_path) + " ! appsink name=sink emit-signals=true sync=false";
}

auto create_video_inference_pipeline(const std::string &video_source,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  const std::string &output_sink) -> std::expected<GStreamerPipeline, GStreamerError>
{

    auto init_result = GStreamerPipeline::initialize_gstreamer();
    if (!init_result) { return std::unexpected(init_result.error()); }

    GStreamerPipeline pipeline;

    auto result = pipeline.create_pipeline_from_string(
      video_inference_pipeline_description(video_source, model_path, width, height, output_sink));
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

auto create_camera_inference_pipeline(const std::string &device,
  const std::string &model_path,
  std::uint32_t width,
  std::uint32_t height,
  std::uint32_t fps) -> std::expected<GStreamerPipeline, GStreamerError>
{

    auto init_result = GStreamerPipeline::initialize_gstreamer();
    if (!init_result) { return std::unexpected(init_result.error()); }

    GStreamerPipeline pipeline;

    auto result = pipeline.create_pipeline_from_string(
      camera_inference_pipeline_description(device, model_path, width, height, fps));
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

}// namespace kataglyphis::gstreamer
