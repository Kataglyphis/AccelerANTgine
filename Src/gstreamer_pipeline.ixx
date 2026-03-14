module;

#include "kataglyphis_export.h"
#include <memory>
#include <functional>
#include <string>
#include <expected>
#include <filesystem>

export module kataglyphis.gstreamer_pipeline;

export namespace kataglyphis::gstreamer {

enum class GStreamerError {
    InitializationFailed,
    PipelineCreationFailed,
    ElementCreationFailed,
    LinkFailed,
    StateChangeFailed,
    BufferAllocationFailed,
    CapsNegotiationFailed,
    StreamError,
    InvalidParameter,
    ResourceNotFound
};

struct TensorMeta {
    std::size_t tensor_index{0};
    std::size_t num_tensors{0};
    std::vector<std::size_t> dimensions;
    int data_type{0};
};

struct FrameMetadata {
    std::uint32_t width{0};
    std::uint32_t height{0};
    std::uint32_t fps_n{0};
    std::uint32_t fps_d{1};
    std::string format;
    std::uint64_t timestamp_ns{0};
    std::uint64_t duration_ns{0};
};

struct BufferInfo {
    void* data{nullptr};
    std::size_t size{0};
    FrameMetadata metadata;
    std::vector<TensorMeta> tensors;
};

using BufferCallback = std::function<void(const BufferInfo&)>;

struct PipelineConfig {
    std::string pipeline_description;
    bool enable_tensor_meta{false};
    bool synchronous_mode{true};
    std::uint32_t timeout_ms{5000};
};

class KATAGLYPHIS_CPP_API GStreamerPipeline {
public:
    GStreamerPipeline();
    ~GStreamerPipeline();
    
    GStreamerPipeline(const GStreamerPipeline&) = delete;
    GStreamerPipeline& operator=(const GStreamerPipeline&) = delete;
    GStreamerPipeline(GStreamerPipeline&&) noexcept;
    GStreamerPipeline& operator=(GStreamerPipeline&&) noexcept;
    
    [[nodiscard]] static auto initialize_gstreamer(int* argc = nullptr, char*** argv = nullptr)
        -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] static auto deinitialize_gstreamer() -> void;
    
    [[nodiscard]] auto create_pipeline(const PipelineConfig& config)
        -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] auto create_pipeline_from_string(const std::string& description)
        -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] auto create_inference_pipeline(
        const std::string& input_source,
        const std::string& model_path,
        const std::vector<std::size_t>& input_shape,
        const std::string& output_format = "RAW"
    ) -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] auto start() -> std::expected<void, GStreamerError>;
    [[nodiscard]] auto stop() -> std::expected<void, GStreamerError>;
    [[nodiscard]] auto pause() -> std::expected<void, GStreamerError>;
    [[nodiscard]] auto resume() -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] auto is_playing() const -> bool;
    [[nodiscard]] auto is_paused() const -> bool;
    
    auto set_buffer_callback(BufferCallback callback) -> void;
    
    [[nodiscard]] auto pull_sample(std::uint32_t timeout_ms = 5000)
        -> std::expected<BufferInfo, GStreamerError>;
    
    [[nodiscard]] auto push_buffer(
        void* data,
        std::size_t size,
        const FrameMetadata& metadata
    ) -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] auto get_position_ns() const -> std::expected<std::uint64_t, GStreamerError>;
    [[nodiscard]] auto get_duration_ns() const -> std::expected<std::uint64_t, GStreamerError>;
    [[nodiscard]] auto seek(std::uint64_t timestamp_ns) -> std::expected<void, GStreamerError>;
    
    [[nodiscard]] auto get_caps_string() const -> std::string;
    [[nodiscard]] auto get_current_state() const -> int;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

[[nodiscard]] auto create_video_inference_pipeline(
    const std::string& video_source,
    const std::string& model_path,
    std::uint32_t width,
    std::uint32_t height,
    const std::string& output_sink = "appsink"
) -> std::expected<GStreamerPipeline, GStreamerError>;

[[nodiscard]] auto create_camera_inference_pipeline(
    const std::string& device,
    const std::string& model_path,
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t fps
) -> std::expected<GStreamerPipeline, GStreamerError>;

}