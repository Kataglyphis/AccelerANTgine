module;

#include "kataglyphis_export.h"
#include <atomic>
#include <cstring>
#include <expected>
#include <gst/analytics/analytics.h>
#include <gst/analytics/gsttensor.h>
#include <gst/analytics/gsttensormeta.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <mutex>
#include <string>
#include <thread>

module kataglyphis.gstreamer_pipeline;

import kataglyphis.project_config;

namespace kataglyphis::gstreamer {

namespace {
    std::atomic<bool> g_gstreamer_initialized{ false };
    std::mutex g_gstreamer_mutex;
}// namespace

struct GStreamerPipeline::Impl
{
    GstElement *pipeline{ nullptr };
    GstElement *appsink{ nullptr };
    GstElement *appsrc{ nullptr };

    BufferCallback buffer_callback;
    std::atomic<bool> is_playing{ false };
    std::atomic<bool> is_paused{ false };
    std::string caps_string;

    GMainLoop *main_loop{ nullptr };
    std::thread main_loop_thread;

    ~Impl() { cleanup(); }

    void cleanup()
    {
        if (pipeline) {
            gst_element_set_state(pipeline, GST_STATE_NULL);
            gst_object_unref(pipeline);
            pipeline = nullptr;
        }
        if (main_loop) {
            g_main_loop_quit(main_loop);
            if (main_loop_thread.joinable()) { main_loop_thread.join(); }
            g_main_loop_unref(main_loop);
            main_loop = nullptr;
        }
    }

    static void on_new_sample(GstElement *sink, Impl *self)
    {
        GstSample *sample = nullptr;
        g_signal_emit_by_name(sink, "pull-sample", &sample);

        if (sample) {
            GstBuffer *buffer = gst_sample_get_buffer(sample);
            GstCaps *caps = gst_sample_get_caps(sample);
            GstMapInfo map_info;

            if (buffer && gst_buffer_map(buffer, &map_info, GST_MAP_READ)) {
                BufferInfo buffer_info;
                buffer_info.data = map_info.data;
                buffer_info.size = map_info.size;

                if (auto *meta = gst_buffer_get_tensor_meta(buffer)) {
                    buffer_info.tensors.reserve(meta->num_tensors);
                    for (gsize i = 0; i < meta->num_tensors; ++i) {
                        const GstTensor *tensor = gst_tensor_meta_get(meta, i);
                        TensorMeta tm;
                        tm.tensor_index = i;
                        tm.num_tensors = meta->num_tensors;
                        tm.data_type = static_cast<int>(tensor->data_type);

                        gsize num_dims = 0;
                        auto dims = gst_tensor_get_dims(const_cast<GstTensor *>(tensor), &num_dims);
                        for (gsize j = 0; j < num_dims; ++j) { tm.dimensions.push_back(dims[j]); }
                        buffer_info.tensors.push_back(std::move(tm));
                    }
                }

                GstStructure *structure = gst_caps_get_structure(caps, 0);
                if (structure) {
                    gst_structure_get_uint(structure, "width", &buffer_info.metadata.width);
                    gst_structure_get_uint(structure, "height", &buffer_info.metadata.height);

                    guint fps_n, fps_d;
                    if (gst_structure_get_fraction(
                          structure, "framerate", reinterpret_cast<gint *>(&fps_n), reinterpret_cast<gint *>(&fps_d))) {
                        buffer_info.metadata.fps_n = fps_n;
                        buffer_info.metadata.fps_d = fps_d;
                    }

                    const gchar *format = gst_structure_get_string(structure, "format");
                    if (format) { buffer_info.metadata.format = format; }
                }

                buffer_info.metadata.timestamp_ns = GST_BUFFER_PTS(buffer);
                buffer_info.metadata.duration_ns = GST_BUFFER_DURATION(buffer);

                if (self->buffer_callback) { self->buffer_callback(buffer_info); }

                gst_buffer_unmap(buffer, &map_info);
            }
            gst_sample_unref(sample);
        }
    }

    static GstPadProbeReturn on_pad_probe(GstPad *pad, GstPadProbeInfo *info, gpointer user_data)
    {
        return GST_PAD_PROBE_OK;
    }
};

GStreamerPipeline::GStreamerPipeline() : impl_(std::make_unique<Impl>()) {}

GStreamerPipeline::~GStreamerPipeline() = default;

GStreamerPipeline::GStreamerPipeline(GStreamerPipeline &&other) noexcept : impl_(std::move(other.impl_)) {}

GStreamerPipeline &GStreamerPipeline::operator=(GStreamerPipeline &&other) noexcept
{
    if (this != &other) { impl_ = std::move(other.impl_); }
    return *this;
}

auto GStreamerPipeline::initialize_gstreamer(int *argc, char ***argv) -> std::expected<void, GStreamerError>
{

    std::lock_guard<std::mutex> lock(g_gstreamer_mutex);

    if (g_gstreamer_initialized.load()) { return {}; }

    GError *error = nullptr;
    if (!gst_init_check(argc, argv, &error)) {
        if (error) { g_error_free(error); }
        return std::unexpected(GStreamerError::InitializationFailed);
    }

    g_gstreamer_initialized.store(true);
    return {};
}

auto GStreamerPipeline::deinitialize_gstreamer() -> void
{
    std::lock_guard<std::mutex> lock(g_gstreamer_mutex);
    if (g_gstreamer_initialized.load()) {
        gst_deinit();
        g_gstreamer_initialized.store(false);
    }
}

auto GStreamerPipeline::create_pipeline(const PipelineConfig &config) -> std::expected<void, GStreamerError>
{

    if (!g_gstreamer_initialized.load()) { return std::unexpected(GStreamerError::InitializationFailed); }

    impl_->cleanup();

    GError *error = nullptr;
    impl_->pipeline = gst_parse_launch(config.pipeline_description.c_str(), &error);

    if (error) {
        g_error_free(error);
        return std::unexpected(GStreamerError::PipelineCreationFailed);
    }

    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    if (config.enable_tensor_meta) {}

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
  const std::vector<std::size_t> &input_shape,
  const std::string &output_format) -> std::expected<void, GStreamerError>
{

    if (!g_gstreamer_initialized.load()) { return std::unexpected(GStreamerError::InitializationFailed); }

    impl_->cleanup();

    std::string shape_str;
    for (std::size_t i = 0; i < input_shape.size(); ++i) {
        if (i > 0) shape_str += ",";
        shape_str += std::to_string(input_shape[i]);
    }

    std::string pipeline_desc;

    if (input_source.find("://") != std::string::npos) {
        pipeline_desc = "uridecodebin uri=" + input_source + " ! ";
    } else if (input_source.find("/dev/video") == 0) {
        pipeline_desc = "v4l2src device=" + input_source + " ! ";
    } else {
        pipeline_desc = "filesrc location=" + input_source + " ! decodebin ! ";
    }

    pipeline_desc +=
      "videoconvert ! videoscale ! "
      "video/x-raw,format=RGB,width=640,height=480 ! "
      "tensor_transform mode=transpose option=1:2:0:3 ! "
      "tensor_transform mode=typecast option=float32 ! "
      "onnxruntime model-path="
      + model_path;

    if (output_format == "TENSOR") { pipeline_desc += " ! tensor_decoder mode=direct"; }

    pipeline_desc += " ! appsink name=sink emit-signals=true";

    GError *error = nullptr;
    impl_->pipeline = gst_parse_launch(pipeline_desc.c_str(), &error);

    if (error) {
        g_error_free(error);
        return std::unexpected(GStreamerError::PipelineCreationFailed);
    }

    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    impl_->appsink = gst_bin_get_by_name(GST_BIN(impl_->pipeline), "sink");
    if (!impl_->appsink) { return std::unexpected(GStreamerError::ElementCreationFailed); }

    g_object_set(impl_->appsink, "emit-signals", TRUE, nullptr);

    return {};
}

auto GStreamerPipeline::start() -> std::expected<void, GStreamerError>
{
    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->is_playing.store(true);
    impl_->is_paused.store(false);
    return {};
}

auto GStreamerPipeline::stop() -> std::expected<void, GStreamerError>
{
    if (!impl_->pipeline) { return {}; }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_NULL);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->is_playing.store(false);
    impl_->is_paused.store(false);
    return {};
}

auto GStreamerPipeline::pause() -> std::expected<void, GStreamerError>
{
    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    GstStateChangeReturn ret = gst_element_set_state(impl_->pipeline, GST_STATE_PAUSED);

    if (ret == GST_STATE_CHANGE_FAILURE) { return std::unexpected(GStreamerError::StateChangeFailed); }

    impl_->is_paused.store(true);
    return {};
}

auto GStreamerPipeline::resume() -> std::expected<void, GStreamerError> { return start(); }

auto GStreamerPipeline::is_playing() const -> bool { return impl_->is_playing.load() && !impl_->is_paused.load(); }

auto GStreamerPipeline::is_paused() const -> bool { return impl_->is_paused.load(); }

auto GStreamerPipeline::set_buffer_callback(BufferCallback callback) -> void
{
    impl_->buffer_callback = std::move(callback);

    if (impl_->appsink) {
        g_signal_connect(impl_->appsink, "new-sample", G_CALLBACK(&Impl::on_new_sample), impl_.get());
    }
}

auto GStreamerPipeline::pull_sample(std::uint32_t timeout_ms) -> std::expected<BufferInfo, GStreamerError>
{

    if (!impl_->appsink) { return std::unexpected(GStreamerError::ElementCreationFailed); }

    GstSample *sample = nullptr;
    g_signal_emit_by_name(impl_->appsink, "pull-sample", &sample);

    if (!sample) { return std::unexpected(GStreamerError::BufferAllocationFailed); }

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstCaps *caps = gst_sample_get_caps(sample);
    GstMapInfo map_info;

    BufferInfo buffer_info;

    if (buffer && gst_buffer_map(buffer, &map_info, GST_MAP_READ)) {
        buffer_info.data = map_info.data;
        buffer_info.size = map_info.size;

        if (caps) {
            GstStructure *structure = gst_caps_get_structure(caps, 0);
            if (structure) {
                gst_structure_get_uint(structure, "width", &buffer_info.metadata.width);
                gst_structure_get_uint(structure, "height", &buffer_info.metadata.height);

                const gchar *format = gst_structure_get_string(structure, "format");
                if (format) { buffer_info.metadata.format = format; }
            }
        }

        if (auto *meta = gst_buffer_get_tensor_meta(buffer)) {
            for (gsize i = 0; i < meta->num_tensors; ++i) {
                const GstTensor *tensor = gst_tensor_meta_get(meta, i);
                TensorMeta tm;
                tm.tensor_index = i;
                tm.num_tensors = meta->num_tensors;
                tm.data_type = static_cast<int>(tensor->data_type);

                gsize num_dims = 0;
                auto dims = gst_tensor_get_dims(const_cast<GstTensor *>(tensor), &num_dims);
                for (gsize j = 0; j < num_dims; ++j) { tm.dimensions.push_back(dims[j]); }
                buffer_info.tensors.push_back(std::move(tm));
            }
        }

        gst_buffer_unmap(buffer, &map_info);
    }

    gst_sample_unref(sample);
    return buffer_info;
}

auto GStreamerPipeline::push_buffer(void *data, std::size_t size, const FrameMetadata &metadata)
  -> std::expected<void, GStreamerError>
{

    if (!impl_->appsrc) { return std::unexpected(GStreamerError::ElementCreationFailed); }

    GstBuffer *buffer = gst_buffer_new_allocate(nullptr, size, nullptr);
    if (!buffer) { return std::unexpected(GStreamerError::BufferAllocationFailed); }

    GstMapInfo map_info;
    if (!gst_buffer_map(buffer, &map_info, GST_MAP_WRITE)) {
        gst_buffer_unref(buffer);
        return std::unexpected(GStreamerError::BufferAllocationFailed);
    }

    std::memcpy(map_info.data, data, size);
    gst_buffer_unmap(buffer, &map_info);

    GST_BUFFER_PTS(buffer) = metadata.timestamp_ns;
    GST_BUFFER_DURATION(buffer) = metadata.duration_ns;

    GstFlowReturn ret;
    g_signal_emit_by_name(impl_->appsrc, "push-buffer", buffer, &ret);
    gst_buffer_unref(buffer);

    if (ret != GST_FLOW_OK) { return std::unexpected(GStreamerError::StreamError); }

    return {};
}

auto GStreamerPipeline::get_position_ns() const -> std::expected<std::uint64_t, GStreamerError>
{
    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    gint64 position;
    if (!gst_element_query_position(impl_->pipeline, GST_FORMAT_TIME, &position)) {
        return std::unexpected(GStreamerError::ResourceNotFound);
    }

    return static_cast<std::uint64_t>(position);
}

auto GStreamerPipeline::get_duration_ns() const -> std::expected<std::uint64_t, GStreamerError>
{
    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    gint64 duration;
    if (!gst_element_query_duration(impl_->pipeline, GST_FORMAT_TIME, &duration)) {
        return std::unexpected(GStreamerError::ResourceNotFound);
    }

    return static_cast<std::uint64_t>(duration);
}

auto GStreamerPipeline::seek(std::uint64_t timestamp_ns) -> std::expected<void, GStreamerError>
{
    if (!impl_->pipeline) { return std::unexpected(GStreamerError::PipelineCreationFailed); }

    if (!gst_element_seek_simple(impl_->pipeline,
          GST_FORMAT_TIME,
          static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
          static_cast<gint64>(timestamp_ns))) {
        return std::unexpected(GStreamerError::ResourceNotFound);
    }

    return {};
}

auto GStreamerPipeline::get_caps_string() const -> std::string { return impl_->caps_string; }

auto GStreamerPipeline::get_current_state() const -> int
{
    if (!impl_->pipeline) { return GST_STATE_NULL; }

    GstState state;
    gst_element_get_state(impl_->pipeline, &state, nullptr, 0);
    return static_cast<int>(state);
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

    std::string pipeline_desc;

    if (video_source.find("://") != std::string::npos) {
        pipeline_desc = "uridecodebin uri=" + video_source + " ! ";
    } else {
        pipeline_desc = "filesrc location=" + video_source + " ! decodebin ! ";
    }

    pipeline_desc += "videoconvert ! videoscale ! "
        "video/x-raw,format=RGB,width=" + std::to_string(width) + 
        ",height=" + std::to_string(height) + " ! "
        "tensor_transform mode=transpose option=1:2:0:3 ! "
        "tensor_transform mode=typecast option=float32 ! "
        "onnxruntime model-path=" + model_path;

    if (output_sink == "appsink") {
        pipeline_desc += " ! appsink name=sink emit-signals=true sync=false";
    } else if (output_sink == "fakesink") {
        pipeline_desc += " ! fakesink sync=false";
    }

    auto result = pipeline.create_pipeline_from_string(pipeline_desc);
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

    std::string pipeline_desc = 
        "v4l2src device=" + device + " ! "
        "video/x-raw,width=" + std::to_string(width) + 
        ",height=" + std::to_string(height) +
        ",framerate=" + std::to_string(fps) + "/1 ! "
        "videoconvert ! "
        "tensor_transform mode=transpose option=1:2:0:3 ! "
        "tensor_transform mode=typecast option=float32 ! "
        "onnxruntime model-path=" + model_path + " ! "
        "appsink name=sink emit-signals=true sync=false";

    auto result = pipeline.create_pipeline_from_string(pipeline_desc);
    if (!result) { return std::unexpected(result.error()); }

    return pipeline;
}

}// namespace kataglyphis::gstreamer