#ifndef KATAGLYPHIS_TEST_SUPPORT_H
#define KATAGLYPHIS_TEST_SUPPORT_H

// Include before any `import`: a header after an import that pulled the same std headers can clash.
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

namespace kataglyphis::test {

// Hand-encoded ONNX protobuf: every lane builds its models itself, so none is checked in or staged.
class ProtoWriter
{
  public:
    void varint(std::uint64_t value)
    {
        while (value >= 0x80U) {
            bytes_.push_back(static_cast<char>((value & 0x7FU) | 0x80U));
            value >>= 7U;
        }
        bytes_.push_back(static_cast<char>(value));
    }

    void key(std::uint32_t field, std::uint32_t wire_type)
    {
        varint((static_cast<std::uint64_t>(field) << 3U) | wire_type);
    }

    void int_field(std::uint32_t field, std::int64_t value)
    {
        key(field, 0);
        varint(static_cast<std::uint64_t>(value));
    }

    void bytes_field(std::uint32_t field, std::string_view value)
    {
        key(field, 2);
        varint(value.size());
        bytes_.append(value);
    }

    void message_field(std::uint32_t field, const ProtoWriter &message) { bytes_field(field, message.bytes()); }

    [[nodiscard]] auto bytes() const -> const std::string & { return bytes_; }

  private:
    std::string bytes_;
};

inline constexpr std::int32_t kOnnxFloat = 1;
inline constexpr std::int32_t kOnnxInt64 = 7;

struct ValueSpec
{
    std::string name;
    std::vector<std::int64_t> dims;
};

struct NodeSpec
{
    std::string op_type;
    std::vector<std::string> inputs;
    std::vector<std::string> outputs;
};

struct Int64Constant
{
    std::string name;
    std::vector<std::int64_t> values;
};

inline auto encode_value_info(const ValueSpec &value) -> ProtoWriter
{
    ProtoWriter shape;
    for (const auto dim : value.dims) {
        ProtoWriter dimension;
        dimension.int_field(1, dim);
        shape.message_field(1, dimension);
    }
    ProtoWriter tensor_type;
    tensor_type.int_field(1, kOnnxFloat);
    tensor_type.message_field(2, shape);
    ProtoWriter type;
    type.message_field(1, tensor_type);
    ProtoWriter info;
    info.bytes_field(1, value.name);
    info.message_field(2, type);
    return info;
}

// ModelProto (IR 8, default-domain opset 13) with float inputs/outputs and 1-D int64 initializers.
inline auto build_onnx_model(const std::vector<ValueSpec> &inputs,
  const std::vector<ValueSpec> &outputs,
  const std::vector<NodeSpec> &nodes,
  const std::vector<Int64Constant> &constants = {}) -> std::string
{
    ProtoWriter graph;
    std::size_t index = 0;
    for (const auto &node_spec : nodes) {
        ProtoWriter node;
        for (const auto &input : node_spec.inputs) { node.bytes_field(1, input); }
        for (const auto &output : node_spec.outputs) { node.bytes_field(2, output); }
        node.bytes_field(3, node_spec.op_type + "_" + std::to_string(index++));
        node.bytes_field(4, node_spec.op_type);
        graph.message_field(1, node);
    }
    graph.bytes_field(2, "kataglyphis_test_graph");
    for (const auto &constant : constants) {
        ProtoWriter tensor;
        tensor.int_field(1, static_cast<std::int64_t>(constant.values.size()));
        tensor.int_field(2, kOnnxInt64);
        ProtoWriter packed;
        for (const auto value : constant.values) { packed.varint(static_cast<std::uint64_t>(value)); }
        tensor.bytes_field(7, packed.bytes());
        tensor.bytes_field(8, constant.name);
        graph.message_field(5, tensor);
    }
    for (const auto &input : inputs) { graph.message_field(11, encode_value_info(input)); }
    for (const auto &output : outputs) { graph.message_field(12, encode_value_info(output)); }

    ProtoWriter opset;
    opset.int_field(2, 13);
    ProtoWriter model;
    model.int_field(1, 8);
    model.bytes_field(2, "kataglyphis-test");
    model.message_field(7, graph);
    model.message_field(8, opset);
    return model.bytes();
}

// X[1,4] -> Relu -> Y[1,4]
inline auto relu_model() -> std::string
{
    return build_onnx_model({ { "X", { 1, 4 } } }, { { "Y", { 1, 4 } } }, { { "Relu", { "X" }, { "Y" } } });
}

// A[2,3] + B[2,3] -> C[2,3]
inline auto add_model() -> std::string
{
    return build_onnx_model(
      { { "A", { 2, 3 } }, { "B", { 2, 3 } } }, { { "C", { 2, 3 } } }, { { "Add", { "A", "B" }, { "C" } } });
}

// X[1,4] -> Relu -> R and X -> Neg -> N: two outputs, in declaration order.
inline auto relu_neg_model() -> std::string
{
    return build_onnx_model({ { "X", { 1, 4 } } },
      { { "R", { 1, 4 } }, { "N", { 1, 4 } } },
      { { "Relu", { "X" }, { "R" } }, { "Neg", { "X" }, { "N" } } });
}

// images[1,3,H,W] reshaped to output[1,rows,values]: the input IS the raw detector output, so tests choose every row.
struct YoloReshapeGeometry
{
    std::int64_t height;
    std::int64_t width;
    std::int64_t rows;
    std::int64_t values_per_row;

    [[nodiscard]] auto elements() const -> std::size_t { return static_cast<std::size_t>(3 * height * width); }
};

inline auto yolo_reshape_model(const YoloReshapeGeometry &geometry) -> std::string
{
    return build_onnx_model({ { "images", { 1, 3, geometry.height, geometry.width } } },
      { { "output", { 1, geometry.rows, geometry.values_per_row } } },
      { { "Reshape", { "images", "shape" }, { "output" } } },
      { { "shape", { 1, geometry.rows, geometry.values_per_row } } });
}

// A uniquely named file that is removed again when the object goes.
class TempFile
{
  public:
    TempFile(std::string_view stem, std::string_view extension, std::string_view contents)
    {
        std::random_device device;
        const auto suffix = (static_cast<std::uint64_t>(device()) << 32U) ^ device();
        path_ = std::filesystem::temp_directory_path()
                / (std::string(stem) + "-" + std::to_string(suffix) + std::string(extension));
        std::ofstream out(path_, std::ios::binary | std::ios::trunc);
        out.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    }

    ~TempFile()
    {
        std::error_code ignored;
        std::filesystem::remove(path_, ignored);
    }

    TempFile(const TempFile &) = delete;
    auto operator=(const TempFile &) -> TempFile & = delete;
    TempFile(TempFile &&) = delete;
    auto operator=(TempFile &&) -> TempFile & = delete;

    [[nodiscard]] auto path() const -> const std::filesystem::path & { return path_; }

  private:
    std::filesystem::path path_;
};

// The error of an expected, or nothing: unlike .error() it is defined when the call unexpectedly succeeded.
template<typename Expected> auto error_of(const Expected &result) -> std::optional<typename Expected::error_type>
{
    if (result.has_value()) { return std::nullopt; }
    return result.error();
}

// A path in the temp directory that nothing created.
inline auto missing_path(std::string_view name) -> std::filesystem::path
{
    return std::filesystem::temp_directory_path() / "kataglyphis-test-does-not-exist" / std::string(name);
}

}// namespace kataglyphis::test

#endif// KATAGLYPHIS_TEST_SUPPORT_H
