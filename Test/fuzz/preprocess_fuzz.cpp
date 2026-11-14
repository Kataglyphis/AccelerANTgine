#include "fuzztest/fuzztest.h"
#include "gtest/gtest.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <vector>

import kataglyphis.gstreamer_pipeline;
import kataglyphis.yolo_detector;

namespace detection = kataglyphis::detection;
namespace gstreamer = kataglyphis::gstreamer;

namespace {

// The target size stays small: the answer is 3*w*h floats, and a fuzzed 65535x65535 would only exhaust memory.
constexpr std::uint32_t kMaxTarget = 48;

// The slow nearest-floor sampler the fast one must equal; nullopt when a pixel lies past the declared size.
auto reference(const std::vector<std::uint8_t> &bytes,
  std::size_t declared,
  const gstreamer::FrameMetadata &meta,
  std::uint32_t width,
  std::uint32_t height,
  detection::FramePreprocessMode mode) -> std::optional<std::vector<float>>
{
    const std::size_t channels = meta.format == "RGB" ? 3 : 4;
    const std::size_t stride = meta.row_stride_bytes == 0 ? static_cast<std::size_t>(meta.width) * channels
                                                          : static_cast<std::size_t>(meta.row_stride_bytes);
    std::uint32_t content_width = width;
    std::uint32_t content_height = height;
    const bool letterbox = mode == detection::FramePreprocessMode::Letterbox;
    if (letterbox) {
        const double ratio =
          std::min(static_cast<double>(width) / meta.width, static_cast<double>(height) / meta.height);
        content_width = std::clamp(static_cast<std::uint32_t>(std::round(meta.width * ratio)), 1U, width);
        content_height = std::clamp(static_cast<std::uint32_t>(std::round(meta.height * ratio)), 1U, height);
    }
    const std::size_t plane = static_cast<std::size_t>(width) * height;
    std::vector<float> expected(3 * plane, letterbox ? 114.0F / 255.0F : 0.0F);
    const std::uint32_t pad_x = (width - content_width) / 2;
    const std::uint32_t pad_y = (height - content_height) / 2;
    for (std::uint32_t y = 0; y < content_height; ++y) {
        const std::uint64_t source_y = static_cast<std::uint64_t>(y) * meta.height / content_height;
        for (std::uint32_t x = 0; x < content_width; ++x) {
            const std::uint64_t source_x = static_cast<std::uint64_t>(x) * meta.width / content_width;
            const std::size_t at = meta.plane_offset_bytes + (source_y * stride) + (source_x * channels);
            const std::size_t out = (static_cast<std::size_t>(y + pad_y) * width) + x + pad_x;
            if (at > declared || declared - at < 3 || declared > bytes.size()) { return std::nullopt; }
            for (std::size_t channel = 0; channel < 3; ++channel) {
                expected[(channel * plane) + out] = static_cast<float>(bytes[at + channel]) / 255.0F;
            }
        }
    }
    return expected;
}

}// namespace

// Reads stay inside the buffer whatever it claims; cxx.preprocess-height-bound-removed drops a bound and fails here.
void NeverReadsOutsideTheBuffer(const std::string &format,
  std::uint32_t frame_width,
  std::uint32_t frame_height,
  std::int64_t stride,
  std::size_t offset,
  const std::vector<std::uint8_t> &bytes,
  int declared_minus_real,
  std::uint32_t width,
  std::uint32_t height,
  bool letterbox)
{
    gstreamer::BufferInfo buffer;
    for (const auto value : bytes) { buffer.data.push_back(static_cast<std::byte>(value)); }
    const auto declared = static_cast<std::int64_t>(bytes.size()) + declared_minus_real;
    buffer.size = static_cast<std::size_t>(std::max<std::int64_t>(declared, 0));
    buffer.metadata.format = format;
    buffer.metadata.width = frame_width;
    buffer.metadata.height = frame_height;
    buffer.metadata.row_stride_bytes = stride;
    buffer.metadata.plane_offset_bytes = offset;
    const auto mode = letterbox ? detection::FramePreprocessMode::Letterbox : detection::FramePreprocessMode::Stretch;

    const auto result = detection::preprocess_frame(buffer, width, height, mode);
    if (!result.has_value()) {
        EXPECT_TRUE(result.error() == detection::OnnxError::InvalidInputShape
                    || result.error() == detection::OnnxError::InvalidInputType);
        return;
    }
    ASSERT_EQ(result->data.size(), 3U * width * height);
    for (const float value : result->data) {
        ASSERT_GE(value, 0.0F);
        ASSERT_LE(value, 1.0F);
    }
    const auto expected = reference(bytes, buffer.size, buffer.metadata, width, height, mode);
    ASSERT_TRUE(expected.has_value()) << "an accepted geometry samples past the buffer's declared size";
    EXPECT_EQ(result->data, *expected);
}
FUZZ_TEST(PreprocessFuzz, NeverReadsOutsideTheBuffer)
  .WithDomains(fuzztest::ElementOf<std::string>({ "RGB", "RGBA", "BGR", "" }),
    fuzztest::OneOf(fuzztest::InRange<std::uint32_t>(0, 24), fuzztest::Arbitrary<std::uint32_t>()),
    fuzztest::OneOf(fuzztest::InRange<std::uint32_t>(0, 24), fuzztest::Arbitrary<std::uint32_t>()),
    fuzztest::OneOf(fuzztest::InRange<std::int64_t>(-2, 128), fuzztest::Arbitrary<std::int64_t>()),
    fuzztest::OneOf(fuzztest::InRange<std::size_t>(0, 64), fuzztest::Arbitrary<std::size_t>()),
    fuzztest::VectorOf(fuzztest::Arbitrary<std::uint8_t>()).WithMaxSize(4096),
    fuzztest::InRange(-8, 8),
    fuzztest::InRange<std::uint32_t>(0, kMaxTarget),
    fuzztest::InRange<std::uint32_t>(0, kMaxTarget),
    fuzztest::Arbitrary<bool>());

// The text between the quotes, read back by gst-launch's rule: a backslash takes the next character as it is.
auto unescape(const std::string &inner) -> std::optional<std::string>
{
    std::string value;
    for (std::size_t at = 0; at < inner.size(); ++at) {
        if (inner[at] == '"') { return std::nullopt; }
        if (inner[at] == '\\') {
            if (++at == inner.size()) { return std::nullopt; }
        }
        value.push_back(inner[at]);
    }
    return value;
}

// A file name inside a pipeline string can neither end its quotes early nor come back changed.
void QuotedValuesRoundTrip(const std::string &value)
{
    const std::string quoted = gstreamer::quote_pipeline_value(value);
    ASSERT_GE(quoted.size(), 2U);
    ASSERT_EQ(quoted.front(), '"');
    ASSERT_EQ(quoted.back(), '"');
    const auto back = unescape(quoted.substr(1, quoted.size() - 2));
    ASSERT_TRUE(back.has_value()) << "the quoted text ends its quotes early or ends in a lone backslash";
    EXPECT_EQ(*back, value);
}
FUZZ_TEST(PipelineQuoteFuzz, QuotedValuesRoundTrip)
  .WithSeeds({ { "" }, { "a b.mp4" }, { R"(say "hi")" }, { R"(C:\clips\cat.mp4)" }, { "ends with \\" } });
