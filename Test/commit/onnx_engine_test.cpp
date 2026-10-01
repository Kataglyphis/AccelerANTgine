#include "kataglyphis_test_support.h"

#include <gtest/gtest.h>

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

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
{
    return inference::TensorShape{ std::move(dims) };
}

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
    } else {
        EXPECT_TRUE(result.error() == inference::OnnxError::SessionCreationFailed
                    || result.error() == inference::OnnxError::ModelLoadFailed);
        EXPECT_FALSE(engine.is_initialized());
    }
}
