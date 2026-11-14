#include "kataglyphis_test_support.h"

#include "cuda_probe.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <iterator>
#include <latch>
#include <optional>
#include <random>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include "hip_probe.hpp"
#include "ort_plugin.hpp"

#include <dlfcn.h>
#include <link.h>
#include <onnxruntime_c_api.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

import kataglyphis.onnx_inference;

namespace inference = kataglyphis::inference;
using kataglyphis::test::TempFile;

namespace {

auto initialized_engine(const TempFile &model) -> inference::OnnxInferenceEngine
{
    inference::OnnxInferenceEngine engine;
    const auto result = engine.initialize(inference::create_default_session_config(model.path()));
    EXPECT_TRUE(result.has_value());
    return engine;
}

auto shape(std::vector<std::size_t> dims) -> inference::TensorShape
{ return inference::TensorShape{ std::move(dims) }; }

}// namespace

TEST(TensorShape, TotalElementsIsTheProductOfTheDimensions)
{
    EXPECT_EQ(shape({}).total_elements(), 1U);
    EXPECT_EQ(shape({ 7 }).total_elements(), 7U);
    EXPECT_EQ(shape({ 2, 3, 4 }).total_elements(), 24U);
    EXPECT_EQ(shape({ 1, 3, 640, 640 }).total_elements(), 1228800U);
    EXPECT_EQ(shape({ 5, 0, 2 }).total_elements(), 0U);
}

TEST(OnnxEngine, DefaultSessionConfigIsSequentialCpuWithFourThreads)
{
    const auto config = inference::create_default_session_config("model.onnx");
    EXPECT_EQ(config.model_path, std::filesystem::path("model.onnx"));
    EXPECT_EQ(config.intra_op_num_threads, 4);
    EXPECT_EQ(config.inter_op_num_threads, 4);
    EXPECT_FALSE(config.enable_cuda);
    EXPECT_TRUE(config.enable_memory_pattern);
    EXPECT_EQ(config.execution_mode, inference::ExecutionMode::Sequential);
    EXPECT_TRUE(config.profiling_prefix.empty());
}

TEST(OnnxEngine, ProfilingIsOptInAndRecordsTheExecutionProvider)
{
    const TempFile model("kataglyphis-profile", ".onnx", kataglyphis::test::relu_model());
    inference::OnnxInferenceEngine engine;
    const auto before_init = engine.end_profiling();
    ASSERT_FALSE(before_init.has_value());
    EXPECT_EQ(before_init.error(), inference::OnnxError::SessionNotInitialized);
    auto config = inference::create_default_session_config(model.path());
    ASSERT_TRUE(engine.initialize(config).has_value());
    const auto disabled = engine.end_profiling();
    ASSERT_FALSE(disabled.has_value());
    EXPECT_EQ(disabled.error(), inference::OnnxError::ProfilingNotEnabled);
    config.profiling_prefix = model.path().string() + "-profile";
    ASSERT_TRUE(engine.initialize(config).has_value());
    const std::vector<float> input{ -1, 0, 1, 2 };
    ASSERT_TRUE(engine.run_inference(input, shape({ 1, 4 }), "X").has_value());
    const auto profile = engine.end_profiling();
    ASSERT_TRUE(profile.has_value());
    std::ifstream file(*profile);
    ASSERT_TRUE(file.good());
    const std::string contents{ std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>() };
    EXPECT_NE(contents.find("CPUExecutionProvider"), std::string::npos);
    file.close();
    std::error_code ignored;
    std::filesystem::remove(*profile, ignored);
    const auto finished = engine.end_profiling();
    ASSERT_FALSE(finished.has_value());
    EXPECT_EQ(finished.error(), inference::OnnxError::ProfilingNotEnabled);
}

TEST(OnnxEngine, RejectsIntegerAndBooleanOutputsBeforeReadingTheirStorage)
{
    for (const std::int32_t type : { 2, 7, 9 }) {
        const TempFile model("kataglyphis-cast", ".onnx", kataglyphis::test::cast_output_model(type));
        auto engine = initialized_engine(model);
        const std::vector<float> input{ 0, 1, 2, 3 };
        const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
        ASSERT_FALSE(result.has_value()) << type;
        EXPECT_EQ(result.error(), inference::OnnxError::InvalidOutputType) << type;
    }
}

TEST(OnnxEngine, RejectsASequenceOutputWithoutAborting)
{
    const TempFile model("kataglyphis-sequence", ".onnx", kataglyphis::test::sequence_output_model());
    auto engine = initialized_engine(model);
    const std::vector<float> input{ 0, 1, 2, 3 };
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::InvalidOutputType);
}

TEST(OnnxEngine, EverythingFailsCleanlyBeforeInitialize)
{
    inference::OnnxInferenceEngine engine;
    EXPECT_FALSE(engine.is_initialized());
    EXPECT_TRUE(engine.get_input_names().empty());
    EXPECT_TRUE(engine.get_output_names().empty());

    const std::vector<float> input(4, 1.0F);
    const auto run = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_FALSE(run.has_value());
    EXPECT_EQ(run.error(), inference::OnnxError::SessionNotInitialized);

    const auto multi = engine.run_inference_multi_input({});
    ASSERT_FALSE(multi.has_value());
    EXPECT_EQ(multi.error(), inference::OnnxError::SessionNotInitialized);

    const auto input_shape = engine.get_input_shape("X");
    ASSERT_FALSE(input_shape.has_value());
    EXPECT_EQ(input_shape.error(), inference::OnnxError::SessionNotInitialized);

    const auto output_shape = engine.get_output_shape("Y");
    ASSERT_FALSE(output_shape.has_value());
    EXPECT_EQ(output_shape.error(), inference::OnnxError::SessionNotInitialized);
}

TEST(OnnxEngine, AMissingModelIsModelLoadFailed)
{
    inference::OnnxInferenceEngine engine;
    const auto result =
      engine.initialize(inference::create_default_session_config(kataglyphis::test::missing_path("model.onnx")));
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::ModelLoadFailed);
    EXPECT_FALSE(engine.is_initialized());
}

TEST(OnnxEngine, AFileThatIsNoModelIsModelLoadFailed)
{
    const TempFile garbage("kataglyphis-garbage", ".onnx", "this is not a protobuf ModelProto");
    inference::OnnxInferenceEngine engine;
    const auto result = engine.initialize(inference::create_default_session_config(garbage.path()));
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::ModelLoadFailed);
    EXPECT_FALSE(engine.is_initialized());
}

TEST(OnnxEngine, ReportsInputAndOutputNamesAndShapes)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    const auto engine = initialized_engine(model);
    ASSERT_TRUE(engine.is_initialized());
    EXPECT_EQ(engine.get_input_names(), (std::vector<std::string>{ "X" }));
    EXPECT_EQ(engine.get_output_names(), (std::vector<std::string>{ "Y" }));

    const auto input_shape = engine.get_input_shape("X");
    ASSERT_TRUE(input_shape.has_value());
    EXPECT_EQ(input_shape->dimensions, (std::vector<std::optional<std::size_t>>{ 1, 4 }));

    const auto output_shape = engine.get_output_shape("Y");
    ASSERT_TRUE(output_shape.has_value());
    EXPECT_EQ(output_shape->dimensions, (std::vector<std::optional<std::size_t>>{ 1, 4 }));
}

TEST(OnnxEngine, ADynamicDimensionIsReportedAsDynamic)
{
    // ONNX Runtime says -1; cast to size_t it read as SIZE_MAX, a 18-quintillion-wide input.
    const TempFile model("kataglyphis-dynamic", ".onnx", kataglyphis::test::dynamic_relu_model());
    const auto engine = initialized_engine(model);
    const auto input_shape = engine.get_input_shape("X");
    ASSERT_TRUE(input_shape.has_value());
    EXPECT_EQ(input_shape->dimensions, (std::vector<std::optional<std::size_t>>{ std::nullopt, 4 }));
}

TEST(OnnxEngine, TheShapeOfASequenceOutputIsInvalidOutputType)
{
    // A sequence has no tensor shape: the wrapper's GetTensorTypeAndShapeInfo read through a null info here.
    const TempFile model("kataglyphis-sequence", ".onnx", kataglyphis::test::sequence_output_model());
    const auto engine = initialized_engine(model);
    const auto output_shape = engine.get_output_shape("Y");
    ASSERT_FALSE(output_shape.has_value());
    EXPECT_EQ(output_shape.error(), inference::OnnxError::InvalidOutputType);
    EXPECT_TRUE(engine.get_input_shape("X").has_value());
}

TEST(OnnxEngine, AnUnknownNameHasNoShape)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    const auto engine = initialized_engine(model);
    const auto input_shape = engine.get_input_shape("Y");
    ASSERT_FALSE(input_shape.has_value());
    EXPECT_EQ(input_shape.error(), inference::OnnxError::OutputNotFound);
    const auto output_shape = engine.get_output_shape("missing");
    ASSERT_FALSE(output_shape.has_value());
    EXPECT_EQ(output_shape.error(), inference::OnnxError::OutputNotFound);
}

TEST(OnnxEngine, RunsInPlaceOnTheCallersBufferWithoutChangingIt)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);

    std::vector<float> input{ -1.0F, 0.0F, 2.5F, -3.0F };
    const auto result = engine.run_inference_in_place(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 0.0F, 0.0F, 2.5F, 0.0F }));
    EXPECT_EQ(input, (std::vector<float>{ -1.0F, 0.0F, 2.5F, -3.0F }));

    std::vector<float> short_input(3, 1.0F);
    const auto wrong = engine.run_inference_in_place(short_input, shape({ 1, 4 }), "X");
    ASSERT_FALSE(wrong.has_value());
    EXPECT_EQ(wrong.error(), inference::OnnxError::InvalidInputShape);

    inference::OnnxInferenceEngine idle;
    const auto before = idle.run_inference_in_place(input, shape({ 1, 4 }), "X");
    ASSERT_FALSE(before.has_value());
    EXPECT_EQ(before.error(), inference::OnnxError::SessionNotInitialized);
}

TEST(OnnxEngine, RunsAReluModel)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);

    const std::vector<float> input{ -1.0F, 0.0F, 2.5F, -3.0F };
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->outputs.size(), 1U);
    EXPECT_EQ(result->outputs[0].shape.dimensions, (std::vector<std::size_t>{ 1, 4 }));
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 0.0F, 0.0F, 2.5F, 0.0F }));
    EXPECT_GE(result->inference_time_ms, 0.0);
}

TEST(OnnxEngine, ResultsDoNotLeakBetweenRuns)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);
    const std::vector<float> first{ 1.0F, 2.0F, 3.0F, 4.0F };
    const std::vector<float> second{ -1.0F, 5.0F, -2.0F, 0.5F };
    ASSERT_TRUE(engine.run_inference(first, shape({ 1, 4 }), "X").has_value());
    const auto result = engine.run_inference(second, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 0.0F, 5.0F, 0.0F, 0.5F }));
}

TEST(OnnxEngine, AnElementCountThatMissesTheShapeIsInvalidInputShape)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);
    const std::vector<float> input(3, 1.0F);
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::InvalidInputShape);
}

TEST(OnnxEngine, AnUnknownInputNameIsInferenceFailed)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);
    const std::vector<float> input(4, 1.0F);
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "input");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::InferenceFailed);
}

TEST(OnnxEngine, AShapeTheModelRejectsIsInferenceFailed)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);
    const std::vector<float> input(4, 1.0F);
    for (const auto &dims : { std::vector<std::size_t>{ 4, 1 }, std::vector<std::size_t>{ 2, 2 } }) {
        const auto result = engine.run_inference(input, shape(dims), "X");
        ASSERT_FALSE(result.has_value());
        EXPECT_EQ(result.error(), inference::OnnxError::InferenceFailed);
    }
    // The engine is still usable afterwards.
    EXPECT_TRUE(engine.run_inference(input, shape({ 1, 4 }), "X").has_value());
}

TEST(OnnxEngine, RunsAModelWithTwoInputs)
{
    const TempFile model("kataglyphis-add", ".onnx", kataglyphis::test::add_model());
    auto engine = initialized_engine(model);
    EXPECT_EQ(engine.get_input_names(), (std::vector<std::string>{ "A", "B" }));

    const std::vector<std::pair<std::string, inference::TensorData>> inputs{
        { "A", { { 1, 2, 3, 4, 5, 6 }, shape({ 2, 3 }) } },
        { "B", { { 10, 20, 30, -4, -5, -6 }, shape({ 2, 3 }) } },
    };
    const auto result = engine.run_inference_multi_input(inputs);
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->outputs.size(), 1U);
    EXPECT_EQ(result->outputs[0].shape.dimensions, (std::vector<std::size_t>{ 2, 3 }));
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 11, 22, 33, 0, 0, 0 }));
}

TEST(OnnxEngine, AMissingInputIsInferenceFailed)
{
    const TempFile model("kataglyphis-add", ".onnx", kataglyphis::test::add_model());
    auto engine = initialized_engine(model);
    const std::vector<std::pair<std::string, inference::TensorData>> inputs{
        { "A", { { 1, 2, 3, 4, 5, 6 }, shape({ 2, 3 }) } },
    };
    const auto result = engine.run_inference_multi_input(inputs);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::InferenceFailed);
}

TEST(OnnxEngine, AMultiInputCountMismatchIsInvalidInputShape)
{
    const TempFile model("kataglyphis-add", ".onnx", kataglyphis::test::add_model());
    auto engine = initialized_engine(model);
    const std::vector<std::pair<std::string, inference::TensorData>> inputs{
        { "A", { { 1, 2, 3, 4, 5, 6 }, shape({ 2, 3 }) } },
        { "B", { { 1, 2, 3 }, shape({ 2, 3 }) } },
    };
    const auto result = engine.run_inference_multi_input(inputs);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(), inference::OnnxError::InvalidInputShape);
}

TEST(OnnxEngine, OutputsComeBackInTheModelsOrder)
{
    const TempFile model("kataglyphis-relu-neg", ".onnx", kataglyphis::test::relu_neg_model());
    auto engine = initialized_engine(model);
    EXPECT_EQ(engine.get_output_names(), (std::vector<std::string>{ "R", "N" }));

    const std::vector<float> input{ -2.0F, 1.0F, 0.0F, 3.5F };
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result->outputs.size(), 2U);
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 0.0F, 1.0F, 0.0F, 3.5F }));
    EXPECT_EQ(result->outputs[1].data, (std::vector<float>{ 2.0F, -1.0F, -0.0F, -3.5F }));
}

TEST(OnnxEngine, ReinitializingSwitchesTheModel)
{
    const TempFile relu("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    const TempFile add("kataglyphis-add", ".onnx", kataglyphis::test::add_model());
    auto engine = initialized_engine(relu);
    ASSERT_TRUE(engine.initialize(inference::create_default_session_config(add.path())).has_value());
    EXPECT_EQ(engine.get_input_names(), (std::vector<std::string>{ "A", "B" }));
    EXPECT_EQ(engine.get_output_names(), (std::vector<std::string>{ "C" }));
}

TEST(OnnxEngine, AFailedReinitializeLeavesNoHalfSession)
{
    const TempFile relu("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(relu);
    const auto result =
      engine.initialize(inference::create_default_session_config(kataglyphis::test::missing_path("gone.onnx")));
    ASSERT_FALSE(result.has_value());
    EXPECT_FALSE(engine.is_initialized());
    EXPECT_TRUE(engine.get_input_names().empty());
    const std::vector<float> input(4, 1.0F);
    const auto run = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_FALSE(run.has_value());
    EXPECT_EQ(run.error(), inference::OnnxError::SessionNotInitialized);
}

TEST(OnnxEngine, AMovedEngineKeepsItsSession)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto engine = initialized_engine(model);
    inference::OnnxInferenceEngine moved(std::move(engine));
    ASSERT_TRUE(moved.is_initialized());
    const std::vector<float> input{ 1.0F, -1.0F, 1.0F, -1.0F };
    const auto result = moved.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 1.0F, 0.0F, 1.0F, 0.0F }));
}

TEST(OnnxEngine, RunsInParallelModeWithoutTheMemoryPattern)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.execution_mode = inference::ExecutionMode::Parallel;
    config.enable_memory_pattern = false;
    config.intra_op_num_threads = 1;
    config.inter_op_num_threads = 1;
    inference::OnnxInferenceEngine engine;
    ASSERT_TRUE(engine.initialize(config).has_value());
    const std::vector<float> input{ 3.0F, -3.0F, 0.25F, -0.25F };
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 3.0F, 0.0F, 0.25F, 0.0F }));
}

TEST(OnnxEngine, ACudaRequestWithoutCudaFailsInsteadOfAborting)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.enable_cuda = true;
    inference::OnnxInferenceEngine engine;
    const auto result = engine.initialize(config);
    if (result.has_value()) {
        // An ORT with a working CUDA provider: the session must then also run.
        const std::vector<float> input{ 1.0F, -1.0F, 2.0F, -2.0F };
        EXPECT_TRUE(engine.run_inference(input, shape({ 1, 4 }), "X").has_value());
    } else if (!inference::provider_available(inference::ExecutionProvider::Cuda)) {
        EXPECT_EQ(result.error(), inference::OnnxError::ProviderUnavailable);
        EXPECT_FALSE(engine.is_initialized());
    } else {
        EXPECT_TRUE(result.error() == inference::OnnxError::SessionCreationFailed
                    || result.error() == inference::OnnxError::ModelLoadFailed);
        EXPECT_FALSE(engine.is_initialized());
    }
}

TEST(OnnxEngine, RejectsConflictingProvidersAndInvalidDevice)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.enable_cuda = true;
    config.execution_provider = inference::ExecutionProvider::MigraphX;
    inference::OnnxInferenceEngine engine;
    EXPECT_EQ(engine.initialize(config).error(), inference::OnnxError::SessionCreationFailed);
    EXPECT_FALSE(engine.is_initialized());

    config.enable_cuda = false;
    config.device_id = -1;
    EXPECT_EQ(engine.initialize(config).error(), inference::OnnxError::SessionCreationFailed);
    EXPECT_FALSE(engine.is_initialized());
}

TEST(OnnxEngine, InvalidMigraphXDeviceFailsWithoutInitializing)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.execution_provider = inference::ExecutionProvider::MigraphX;
    config.device_id = 999;
    inference::OnnxInferenceEngine engine;
    // No module, no card or no such device: each is the provider that cannot be had, with the reason kept.
    EXPECT_EQ(kataglyphis::test::error_of(engine.initialize(config)), inference::OnnxError::ProviderUnavailable);
    EXPECT_FALSE(engine.is_initialized());
    EXPECT_FALSE(engine.provider_error().empty());
}

#if !defined(_WIN32)
TEST(HipProbe, WorkThatFinishesAnswers)
{
    EXPECT_TRUE(inference::hip_probe::answers_within(std::chrono::seconds(30), [] {}));
}

TEST(HipProbe, AChildThatCrashesCountsAsAnAnswer)
{
    EXPECT_TRUE(inference::hip_probe::answers_within(std::chrono::seconds(30), [] {
        // No core file: where dumps are on, the abort leaves one in the directory the test ran in.
        const rlimit none{ 0, 0 };
        (void)setrlimit(RLIMIT_CORE, &none);
        std::abort();
    }));
}

TEST(HipProbe, WorkThatNeverReturnsDoesNotAnswer)
{
    EXPECT_FALSE(inference::hip_probe::answers_within(std::chrono::milliseconds(100), [] {
        while (true) { pause(); }
    }));
}

TEST(HipProbe, AMissingRuntimeOrOneWithoutTheSymbolsCopiesNothing)
{
    inference::hip_probe::copy_to_device("libnot-a-hip-runtime.so", 0);
    inference::hip_probe::copy_to_device("libc.so.6", 0);
}
#endif

TEST(CudaProbe, ACardWithoutAKernelIsNamedWithTheWayOut)
{
    const auto reason = inference::cuda_probe::no_kernel_reason(
      "Status Message: CUDA error cudaErrorNoKernelImageForDevice:no kernel image is available",
      [] { return std::optional<std::string>("NVIDIA GeForce RTX 2080 (compute capability 7.5)"); });
    ASSERT_TRUE(reason.has_value());
    EXPECT_NE(reason->find("NVIDIA GeForce RTX 2080 (compute capability 7.5)"), std::string::npos) << *reason;
    EXPECT_NE(reason->find("cpu device runs on the CPU"), std::string::npos) << *reason;
}

TEST(CudaProbe, ACardTheDriverDoesNotNameStillFails)
{
    const auto reason = inference::cuda_probe::no_kernel_reason(
      "cudaErrorNoKernelImageForDevice", [] { return std::optional<std::string>{}; });
    ASSERT_TRUE(reason.has_value());
    EXPECT_NE(reason->find("this NVIDIA GPU"), std::string::npos) << *reason;
}

TEST(CudaProbe, EveryOtherOutcomeIsLeftToTheRealSession)
{
    const auto never = []() -> std::optional<std::string> {
        ADD_FAILURE() << "only a missing kernel asks for the card";
        return std::nullopt;
    };
    EXPECT_FALSE(inference::cuda_probe::no_kernel_reason("", never).has_value());
    EXPECT_FALSE(inference::cuda_probe::no_kernel_reason("CUDA failure 999: Unknown error", never).has_value());
}

TEST(CudaProbe, NoDriverOrOneWithoutTheSymbolsNamesNothing)
{
    EXPECT_FALSE(inference::cuda_probe::card_on("libnot-a-cuda-driver.so", 0).has_value());
#if !defined(_WIN32)
    EXPECT_FALSE(inference::cuda_probe::card_on("libc.so.6", 0).has_value());
#endif
}

TEST(CudaProbe, TheModelRunsItsOneKernelOnTheCpu)
{
    const auto bytes = inference::cuda_probe::one_kernel();
    const TempFile model(
      "kataglyphis-one-kernel", ".onnx", std::string_view(reinterpret_cast<const char *>(bytes.data()), bytes.size()));
    auto engine = initialized_engine(model);
    const std::vector<float> input{ -1.0F };
    const auto output = engine.run_inference(input, shape({ 1 }), "x");
    ASSERT_TRUE(output.has_value());
    EXPECT_EQ(output->outputs[0].data, (std::vector<float>{ 0.0F }));
}

#if !defined(_WIN32)
namespace {

namespace plugin = inference::ort_plugin;
using Paths = std::vector<std::filesystem::path>;

// A plugin root as the image lays it out: the module, where there is one, is lib/libmigraphx-ep.so.
class PluginRoot
{
  public:
    PluginRoot()
    {
        std::random_device device;
        root_ = std::filesystem::temp_directory_path()
                / ("kataglyphis-plugin-root-" + std::to_string(device()) + "-" + std::to_string(device()));
        std::filesystem::create_directories(root_ / "lib");
    }

    ~PluginRoot()
    {
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }

    PluginRoot(const PluginRoot &) = delete;
    auto operator=(const PluginRoot &) -> PluginRoot & = delete;

    [[nodiscard]] auto path() const -> const std::filesystem::path & { return root_; }
    [[nodiscard]] auto module_path() const -> std::filesystem::path { return root_ / "lib" / "libmigraphx-ep.so"; }

  private:
    std::filesystem::path root_;
};

void write_file(const std::filesystem::path &path, std::string_view contents)
{ std::ofstream(path, std::ios::binary | std::ios::trunc) << contents; }

auto read_file(const std::filesystem::path &path) -> std::string
{
    std::ifstream file(path, std::ios::binary);
    return { std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>() };
}

// Where the loader took ONNX Runtime from, read from its list of objects and not the way the engine asks.
auto loaded_runtime_directory() -> std::filesystem::path
{
    std::filesystem::path found;
    dl_iterate_phdr(
      [](dl_phdr_info *object, std::size_t, void *out) -> int {
          const std::filesystem::path name = object->dlpi_name;
          if (!name.filename().string().starts_with("libonnxruntime.so")) { return 0; }
          std::error_code ignored;
          const auto directory = std::filesystem::canonical(std::filesystem::absolute(name).parent_path(), ignored);
          *static_cast<std::filesystem::path *>(out) = directory;
          return 1;
      },
      &found);
    return found;
}

auto stub_module() -> std::filesystem::path
{ return std::filesystem::path(KATAGLYPHIS_PLUGIN_STUB_ROOT) / "lib" / "libmigraphx-ep.so"; }

auto count_of(std::string_view text, std::string_view part) -> std::size_t
{
    std::size_t found = 0;
    for (auto at = text.find(part); at != std::string_view::npos; at = text.find(part, at + part.size())) { ++found; }
    return found;
}

auto migraphx_row() -> const plugin::Plugin & { return *plugin::plugin_for(inference::ExecutionProvider::MigraphX); }

auto migraphx_config(const TempFile &model, int device_id = 0) -> inference::SessionConfig
{
    auto config = inference::create_default_session_config(model.path());
    config.execution_provider = inference::ExecutionProvider::MigraphX;
    config.device_id = device_id;
    return config;
}

// A named migraphx request that cannot be had: ProviderUnavailable, no session, and a reason that names each text.
void expect_unavailable(const inference::SessionConfig &config, std::initializer_list<std::string> named)
{
    inference::OnnxInferenceEngine engine;
    EXPECT_EQ(kataglyphis::test::error_of(engine.initialize(config)), inference::OnnxError::ProviderUnavailable);
    EXPECT_FALSE(engine.is_initialized());
    for (const auto &text : named) {
        EXPECT_NE(engine.provider_error().find(text), std::string::npos) << engine.provider_error();
    }
    EXPECT_EQ(engine.provider_error().find("already registered"), std::string::npos) << engine.provider_error();
}

// The model's Relu must give these values wherever its nodes ran.
void expect_relu_runs(const inference::SessionConfig &config)
{
    inference::OnnxInferenceEngine engine;
    ASSERT_TRUE(engine.initialize(config).has_value()) << engine.provider_error();
    EXPECT_TRUE(engine.provider_error().empty());
    const std::vector<float> input{ 3.0F, -3.0F, 0.25F, -0.25F };
    const auto output = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(output.has_value());
    EXPECT_EQ(output->outputs[0].data, (std::vector<float>{ 3.0F, 0.0F, 0.25F, 0.0F }));
}

// A registration lasts for the process, so each case with the real ONNX Runtime runs in a child of its own.
template<typename Case> void in_a_child(Case scenario)
{
    EXPECT_EXIT(
      {
          scenario();
          std::exit(::testing::Test::HasFailure() ? 1 : 0);
      },
      ::testing::ExitedWithCode(0),
      "");
}

}// namespace

TEST(OrtPlugin, MigraphXIsThePluginRowAndRegistersAsMIGraphX)
{
    const auto *row = plugin::plugin_for(inference::ExecutionProvider::MigraphX);
    ASSERT_NE(row, nullptr);
    EXPECT_STREQ(row->name, "MIGraphX");
    EXPECT_STREQ(row->root_variable, "ORT_AMDGPU_EP_ROOT");
    EXPECT_STREQ(row->module_file, "libmigraphx-ep.so");
    // A registration name that ends in .virtual switches ONNX Runtime's virtual devices on.
    EXPECT_FALSE(std::string_view(row->name).ends_with(".virtual"));
    for (const auto provider : { inference::ExecutionProvider::Cpu,
           inference::ExecutionProvider::Cuda,
           inference::ExecutionProvider::DirectML,
           inference::ExecutionProvider::Xnnpack,
           inference::ExecutionProvider::Dnnl }) {
        EXPECT_EQ(plugin::plugin_for(provider), nullptr);
    }
}

TEST(OrtPlugin, TheRootComesBeforeTheRuntimeDirectoryAndAnEmptyRootIsNoPlace)
{
    EXPECT_EQ(plugin::module_candidates(migraphx_row(), "/root", "/ort/lib"),
      (Paths{ "/root/lib/libmigraphx-ep.so", "/ort/lib/libmigraphx-ep.so" }));
    EXPECT_EQ(plugin::module_candidates(migraphx_row(), "", "/ort/lib"), (Paths{ "/ort/lib/libmigraphx-ep.so" }));
    EXPECT_TRUE(plugin::module_candidates(migraphx_row(), "", "").empty());
}

TEST(OrtPlugin, TheFirstCandidateThatIsAFileIsTheModule)
{
    const PluginRoot root;
    const PluginRoot runtime;
    const auto beside = runtime.path() / "libmigraphx-ep.so";
    const auto candidates = plugin::module_candidates(migraphx_row(), root.path().string(), runtime.path());
    // The image's root exists and is empty where it ships no module.
    EXPECT_TRUE(plugin::first_file(candidates).empty());
    write_file(beside, "beside the runtime");
    EXPECT_EQ(plugin::first_file(candidates), beside);
    std::filesystem::create_directory(root.module_path());
    EXPECT_EQ(plugin::first_file(candidates), beside);
    std::filesystem::remove(root.module_path());
    write_file(root.module_path(), "under the root");
    EXPECT_EQ(plugin::first_file(candidates), root.module_path());
}

TEST(OrtPlugin, AMissingModuleNamesEveryPathAndTheRule)
{
    const auto candidates = plugin::module_candidates(migraphx_row(), "/root", "/ort/lib");
    const auto reason = plugin::missing_module_reason(migraphx_row(), "/root", candidates);
    for (const std::string text : { "MIGraphX is not available: no libmigraphx-ep.so at /root/lib/libmigraphx-ep.so or "
                                    "/ort/lib/libmigraphx-ep.so.",
           "$ORT_AMDGPU_EP_ROOT/lib when that variable is not empty (it is /root)",
           "then beside the loaded ONNX Runtime library",
           "The cpu device runs on the CPU" }) {
        EXPECT_NE(reason.find(text), std::string::npos) << reason;
    }
    const auto unset =
      plugin::missing_module_reason(migraphx_row(), "", plugin::module_candidates(migraphx_row(), "", "/ort/lib"));
    EXPECT_NE(unset.find("no libmigraphx-ep.so at /ort/lib/libmigraphx-ep.so."), std::string::npos) << unset;
    EXPECT_NE(unset.find("(it is empty)"), std::string::npos) << unset;
}

TEST(OrtPlugin, TheOnlyOptionIsTheDeviceId)
{ EXPECT_EQ(plugin::device_options(3), (std::vector<std::pair<std::string, std::string>>{ { "device_id", "3" } })); }

TEST(OrtPlugin, ANameIsRegisteredOnceAndAFailureIsNotRemembered)
{
    plugin::Registered registered;
    int calls = 0;
    const auto fails = [&calls] {
        ++calls;
        return false;
    };
    const auto succeeds = [&calls] {
        ++calls;
        return true;
    };
    EXPECT_FALSE(registered.ensure("MIGraphX", fails));
    EXPECT_FALSE(registered.ensure("MIGraphX", fails));
    EXPECT_EQ(calls, 2);
    EXPECT_TRUE(registered.ensure("MIGraphX", succeeds));
    EXPECT_TRUE(registered.ensure("MIGraphX", fails));
    EXPECT_EQ(calls, 3);
    EXPECT_TRUE(registered.ensure("Another", succeeds));
    EXPECT_EQ(calls, 4);
}

TEST(OrtPlugin, WithoutAModuleMigraphXFailsAndTheCpuStillRuns)
{
    in_a_child([] {
        const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
        const PluginRoot root;
        // A package carries the module beside the runtime, so that place must be the one the loader used.
        const auto beside = loaded_runtime_directory() / "libmigraphx-ep.so";
        ASSERT_TRUE(beside.is_absolute()) << beside;
        // Every image but the rocm one sets the variable to nothing and keeps an empty directory.
        for (const std::string &value : { std::string{}, root.path().string() }) {
            ASSERT_EQ(setenv("ORT_AMDGPU_EP_ROOT", value.c_str(), 1), 0);
            EXPECT_FALSE(inference::provider_available(inference::ExecutionProvider::MigraphX));
            expect_unavailable(migraphx_config(model),
              { "MIGraphX is not available: no libmigraphx-ep.so at ",
                value.empty() ? std::string("(it is empty)") : root.module_path().string(),
                beside.string(),
                "beside the loaded ONNX Runtime library" });
        }
        expect_relu_runs(inference::create_default_session_config(model.path()));
    });
}

TEST(OrtPlugin, AModuleThatCannotLoadFailsTheSameWayEachTime)
{
    in_a_child([] {
        const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
        const PluginRoot root;
        write_file(root.module_path(), "not a shared object");
        ASSERT_EQ(setenv("ORT_AMDGPU_EP_ROOT", root.path().c_str(), 1), 0);
        // The module on disk is all that availability can say; registration needs the card.
        EXPECT_TRUE(inference::provider_available(inference::ExecutionProvider::MigraphX));
        // ONNX Runtime rolls a failed registration back, so the second request fails as the first did.
        for (int attempt = 0; attempt < 2; ++attempt) {
            expect_unavailable(
              migraphx_config(model), { "MIGraphX failed to register " + root.module_path().string() + ": " });
        }
        expect_relu_runs(inference::create_default_session_config(model.path()));
    });
}

TEST(OrtPlugin, ARegisteredPluginGetsOneDeviceAndOnlyTheDeviceId)
{
    in_a_child([] {
        const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
        const TempFile log("kataglyphis-plugin-stub", ".log", "");
        ASSERT_EQ(setenv("ORT_AMDGPU_EP_ROOT", KATAGLYPHIS_PLUGIN_STUB_ROOT, 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_DEVICES", "2", 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_LOG", log.path().c_str(), 1), 0);
        expect_relu_runs(migraphx_config(model, 1));
        // No engine is left here: the registration must outlive them, and a second one would be refused.
        expect_relu_runs(migraphx_config(model, 0));
        expect_unavailable(migraphx_config(model, 2), { "which offers 2 device(s), so device 2 does not exist" });
        EXPECT_EQ(read_file(log.path()), "devices=1 device_id=1\ndevices=1 device_id=0\n");
    });
}

TEST(OrtPlugin, APluginThatOffersNoDeviceIsProviderUnavailable)
{
    in_a_child([] {
        const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
        const TempFile log("kataglyphis-plugin-stub", ".log", "");
        ASSERT_EQ(setenv("ORT_AMDGPU_EP_ROOT", KATAGLYPHIS_PLUGIN_STUB_ROOT, 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_DEVICES", "0", 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_LOG", log.path().c_str(), 1), 0);
        for (int attempt = 0; attempt < 2; ++attempt) {
            expect_unavailable(migraphx_config(model),
              { "MIGraphX registered " + stub_module().string(),
                "which offers 0 device(s), so device 0 does not exist" });
        }
        EXPECT_TRUE(read_file(log.path()).empty());
        expect_relu_runs(inference::create_default_session_config(model.path()));
    });
}

TEST(OrtPlugin, ThreadsRegisterTheModuleOnceAndEachGetsItsDevice)
{
    in_a_child([] {
        constexpr int requests = 8;
        const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
        const TempFile log("kataglyphis-plugin-stub", ".log", "");
        ASSERT_EQ(setenv("ORT_AMDGPU_EP_ROOT", KATAGLYPHIS_PLUGIN_STUB_ROOT, 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_DEVICES", "2", 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_LOG", log.path().c_str(), 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_REGISTER_MS", "300", 1), 0);
        std::latch start(1);
        std::vector<std::thread> threads;
        for (int request = 0; request < requests; ++request) {
            threads.emplace_back([&model, &start, request] {
                start.wait();
                // A second registration of the name is an error, and it would fail this request.
                expect_relu_runs(migraphx_config(model, request % 2));
            });
        }
        start.count_down();
        for (auto &thread : threads) { thread.join(); }
        const auto seen = read_file(log.path());
        EXPECT_EQ(count_of(seen, "devices=1 device_id=0\n"), requests / 2) << seen;
        EXPECT_EQ(count_of(seen, "devices=1 device_id=1\n"), requests / 2) << seen;
        EXPECT_EQ(std::ranges::count(seen, '\n'), requests) << seen;
    });
}

TEST(OrtPlugin, ANameAnotherLibraryRegisteredIsUsedAndNotRegisteredAgain)
{
    in_a_child([] {
        const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
        const TempFile log("kataglyphis-plugin-stub", ".log", "");
        ASSERT_EQ(setenv("ORT_AMDGPU_EP_ROOT", KATAGLYPHIS_PLUGIN_STUB_ROOT, 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_DEVICES", "1", 1), 0);
        ASSERT_EQ(setenv("KATAGLYPHIS_STUB_EP_LOG", log.path().c_str(), 1), 0);
        // One loaded ONNX Runtime has one environment, whichever library of the process asks for it.
        const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
        ASSERT_NE(api, nullptr);
        OrtEnv *other = nullptr;
        ASSERT_EQ(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "another-library", &other), nullptr);
        ASSERT_EQ(api->RegisterExecutionProviderLibrary(other, migraphx_row().name, stub_module().c_str()), nullptr);
        expect_relu_runs(migraphx_config(model));
        // The engine keeps its own reference, so the registration outlives the library that made it.
        api->ReleaseEnv(other);
        expect_relu_runs(migraphx_config(model));
        EXPECT_EQ(read_file(log.path()), "devices=1 device_id=0\ndevices=1 device_id=0\n");
    });
}
#endif

#if !defined(_WIN32) && defined(KATAGLYPHIS_TEST_MIGRAPHX)
TEST(OnnxEngine, MigraphXInferenceWorksWithoutACacheOverride)
{
    ASSERT_EQ(std::getenv("ORT_MIGRAPHX_MODEL_CACHE_PATH"), nullptr);
    const TempFile model("kataglyphis-migraphx", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.execution_provider = inference::ExecutionProvider::MigraphX;
    config.profiling_prefix = model.path().string() + "-profile";
    inference::OnnxInferenceEngine engine;
    ASSERT_TRUE(engine.initialize(config).has_value());
    const std::vector<float> input{ -1.0F, 0.0F, 2.5F, -3.0F };
    const auto result = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result->outputs[0].data, (std::vector<float>{ 0.0F, 0.0F, 2.5F, 0.0F }));
    const auto profile = engine.end_profiling();
    ASSERT_TRUE(profile.has_value());
    std::ifstream file(*profile);
    ASSERT_TRUE(file.good());
    const std::string contents{ std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>() };
    // The plugin's nodes carry its registration name, quoted whole, and no longer MIGraphXExecutionProvider.
    EXPECT_NE(contents.find("\"MIGraphX\""), std::string::npos);
    file.close();
    std::error_code ignored;
    std::filesystem::remove(*profile, ignored);
}
#endif

#ifndef _WIN32
TEST(OnnxEngine, DirectMLRequestOnNonWindowsFails)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.execution_provider = inference::ExecutionProvider::DirectML;
    inference::OnnxInferenceEngine engine;
    EXPECT_FALSE(inference::provider_available(inference::ExecutionProvider::DirectML));
    EXPECT_EQ(engine.initialize(config).error(), inference::OnnxError::ProviderUnavailable);
    EXPECT_FALSE(engine.is_initialized());
}
#endif

TEST(OnnxEngine, TheCpuProviderIsAlwaysAvailable)
{ EXPECT_TRUE(inference::provider_available(inference::ExecutionProvider::Cpu)); }

namespace {

// What a session on provider must give back for the Relu model, or the ProviderUnavailable error it must fail with.
void expect_runs_like_cpu(inference::ExecutionProvider provider, bool must_run, std::string_view missing_library)
{
    const TempFile model("kataglyphis-relu", ".onnx", kataglyphis::test::relu_model());
    auto config = inference::create_default_session_config(model.path());
    config.execution_provider = provider;
    config.intra_op_num_threads = 2;
    inference::OnnxInferenceEngine engine;
    const auto result = engine.initialize(config);
    if (!must_run) {
        EXPECT_EQ(kataglyphis::test::error_of(result), inference::OnnxError::ProviderUnavailable);
        EXPECT_FALSE(engine.is_initialized());
        EXPECT_EQ(engine.applied_intra_op_num_threads(), 0);
        EXPECT_NE(engine.provider_error().find(missing_library), std::string::npos) << engine.provider_error();
        return;
    }
    ASSERT_TRUE(result.has_value()) << engine.provider_error();
    EXPECT_TRUE(engine.provider_error().empty());
    EXPECT_EQ(engine.applied_intra_op_num_threads(), 2);
    const std::vector<float> input{ 3.0F, -3.0F, 0.25F, -0.25F };
    const auto output = engine.run_inference(input, shape({ 1, 4 }), "X");
    ASSERT_TRUE(output.has_value());
    EXPECT_EQ(output->outputs[0].data, (std::vector<float>{ 3.0F, 0.0F, 0.25F, 0.0F }));
}

}// namespace

TEST(OnnxEngine, XnnpackRunsWhereTheRuntimeHasIt)
{
    const auto provider = inference::ExecutionProvider::Xnnpack;
    expect_runs_like_cpu(provider, inference::provider_available(provider), "XnnpackExecutionProvider");
}

// DNNL needs its provider library and libdnnl: it runs exactly when both load, else ORT names what failed.
TEST(OnnxEngine, DnnlRunsOnlyWhenItsLibraryLoads)
{
    const auto provider = inference::ExecutionProvider::Dnnl;
    if (!inference::provider_available(provider)) {
        expect_runs_like_cpu(provider, false, "DnnlExecutionProvider");
        return;
    }
#if defined(_WIN32)
    HMODULE dnnl = LoadLibraryA("dnnl.dll");
    if (dnnl != nullptr) { FreeLibrary(dnnl); }
#else
    void *dnnl = dlopen("libdnnl.so.3", RTLD_NOW | RTLD_LOCAL);
    if (dnnl != nullptr) { dlclose(dnnl); }
#endif
    expect_runs_like_cpu(provider, dnnl != nullptr, "onnxruntime_providers_");
}

TEST(OnnxEngine, CustomMetadataIsReadFromTheModel)
{
    const TempFile model("kataglyphis-metadata",
      ".onnx",
      kataglyphis::test::yolo_reshape_model({ 1, 2, 1, 6 }, { { "kataglyphis.output", "xyxy_score_class" } }));
    inference::OnnxInferenceEngine engine;
    EXPECT_EQ(kataglyphis::test::error_of(engine.get_custom_metadata("kataglyphis.output")),
      inference::OnnxError::SessionNotInitialized);
    ASSERT_TRUE(engine.initialize(inference::create_default_session_config(model.path())).has_value());
    EXPECT_EQ(engine.get_custom_metadata("kataglyphis.output"), std::string("xyxy_score_class"));
    EXPECT_EQ(engine.get_custom_metadata("kataglyphis.absent"), std::string());
}

TEST(OnnxError, EveryValueHasANameOfItsOwn)
{
    const auto names = kataglyphis::test::names_of<kataglyphis::inference::OnnxError>();
    ASSERT_EQ(names.size(), 17U);
    EXPECT_EQ(names.front(), "SessionCreationFailed");
    EXPECT_EQ(names.back(), "EndOfStream");
    EXPECT_TRUE(kataglyphis::test::all_differ(names));
    EXPECT_EQ(to_string(static_cast<kataglyphis::inference::OnnxError>(17)), "UnknownError");
}
