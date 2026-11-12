#include "kataglyphis_test_support.h"

#include "cuda_probe.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
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

#include <dlfcn.h>
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
    EXPECT_EQ(input_shape->dimensions, (std::vector<std::size_t>{ 1, 4 }));

    const auto output_shape = engine.get_output_shape("Y");
    ASSERT_TRUE(output_shape.has_value());
    EXPECT_EQ(output_shape->dimensions, (std::vector<std::size_t>{ 1, 4 }));
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
    const auto result = engine.initialize(config);
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error(),
      inference::provider_available(inference::ExecutionProvider::MigraphX)
        ? inference::OnnxError::SessionCreationFailed
        : inference::OnnxError::ProviderUnavailable);
    EXPECT_FALSE(engine.is_initialized());
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
    EXPECT_NE(contents.find("MIGraphXExecutionProvider"), std::string::npos);
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
