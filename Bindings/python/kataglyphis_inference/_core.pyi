"""Python bindings for the Kataglyphis C++ ONNX inference engine"""

from collections.abc import Sequence
import enum
import os
import pathlib
from typing import Annotated

import numpy
from numpy.typing import NDArray


__version__: str

HAS_ONNXRUNTIME: bool = True

class MyCalculator:
    def __init__(self) -> None: ...

    def add(self, lhs: int, rhs: int) -> int: ...

    def version(self) -> str: ...

class ConfigError(enum.Enum):
    FileNotFound = 0

    ParseError = 1

    MissingField = 2

    InvalidValue = 3

class VideoConfig:
    def __init__(self) -> None: ...

    @property
    def default_width(self) -> int: ...

    @default_width.setter
    def default_width(self, arg: int, /) -> None: ...

    @property
    def default_height(self) -> int: ...

    @default_height.setter
    def default_height(self, arg: int, /) -> None: ...

    @property
    def default_framerate(self) -> int: ...

    @default_framerate.setter
    def default_framerate(self, arg: int, /) -> None: ...

    @property
    def default_bitrate_kbps(self) -> int: ...

    @default_bitrate_kbps.setter
    def default_bitrate_kbps(self, arg: int, /) -> None: ...

class TextureConfig:
    def __init__(self) -> None: ...

    @property
    def width(self) -> int: ...

    @width.setter
    def width(self, arg: int, /) -> None: ...

    @property
    def height(self) -> int: ...

    @height.setter
    def height(self, arg: int, /) -> None: ...

class AndroidConfig:
    def __init__(self) -> None: ...

    @property
    def width(self) -> int: ...

    @width.setter
    def width(self, arg: int, /) -> None: ...

    @property
    def height(self) -> int: ...

    @height.setter
    def height(self, arg: int, /) -> None: ...

    @property
    def fps(self) -> int: ...

    @fps.setter
    def fps(self, arg: int, /) -> None: ...

class StreamSettingsConfig:
    def __init__(self) -> None: ...

    @property
    def source(self) -> str: ...

    @source.setter
    def source(self, arg: str, /) -> None: ...

    @property
    def encoder(self) -> str: ...

    @encoder.setter
    def encoder(self, arg: str, /) -> None: ...

    @property
    def device(self) -> str: ...

    @device.setter
    def device(self, arg: str, /) -> None: ...

    @property
    def camera_id(self) -> str: ...

    @camera_id.setter
    def camera_id(self, arg: str, /) -> None: ...

    @property
    def input_path(self) -> str: ...

    @input_path.setter
    def input_path(self, arg: str, /) -> None: ...

    @property
    def input_uri(self) -> str: ...

    @input_uri.setter
    def input_uri(self, arg: str, /) -> None: ...

    @property
    def peer_id(self) -> str: ...

    @peer_id.setter
    def peer_id(self, arg: str, /) -> None: ...

    @property
    def producer_id(self) -> str: ...

    @producer_id.setter
    def producer_id(self, arg: str, /) -> None: ...

class WebRTCConfig:
    def __init__(self) -> None: ...

    @property
    def signaling_server_url(self) -> str: ...

    @signaling_server_url.setter
    def signaling_server_url(self, arg: str, /) -> None: ...

    @property
    def reconnection_timeout_ms(self) -> int: ...

    @reconnection_timeout_ms.setter
    def reconnection_timeout_ms(self, arg: int, /) -> None: ...

    @property
    def stun_servers(self) -> list[str]: ...

    @stun_servers.setter
    def stun_servers(self, arg: Sequence[str], /) -> None: ...

    @property
    def turn_servers(self) -> list[str]: ...

    @turn_servers.setter
    def turn_servers(self, arg: Sequence[str], /) -> None: ...

    @property
    def video(self) -> VideoConfig: ...

    @video.setter
    def video(self, arg: VideoConfig, /) -> None: ...

    @property
    def texture(self) -> TextureConfig: ...

    @texture.setter
    def texture(self, arg: TextureConfig, /) -> None: ...

    @property
    def android(self) -> AndroidConfig: ...

    @android.setter
    def android(self, arg: AndroidConfig, /) -> None: ...

    @property
    def stream(self) -> StreamSettingsConfig: ...

    @stream.setter
    def stream(self, arg: StreamSettingsConfig, /) -> None: ...

def load_webrtc_config(config_path: str | os.PathLike) -> WebRTCConfig:
    """Load WebRTC configuration from a JSON file."""

def parse_webrtc_config(json_content: str) -> WebRTCConfig:
    """Parse WebRTC configuration from a JSON string."""

def get_default_webrtc_config() -> WebRTCConfig:
    """Get the default WebRTC configuration."""

class ExecutionProvider(enum.Enum):
    CPU = 0

    CUDA = 1

    DIRECTML = 2

class FinishReason(enum.Enum):
    STOP = 0

    LENGTH = 1

    CANCELLED = 2

class GenerationOptions:
    def __init__(self) -> None: ...

    @property
    def max_new_tokens(self) -> int: ...

    @max_new_tokens.setter
    def max_new_tokens(self, arg: int, /) -> None: ...

    @property
    def temperature(self) -> float: ...

    @temperature.setter
    def temperature(self, arg: float, /) -> None: ...

    @property
    def top_p(self) -> float: ...

    @top_p.setter
    def top_p(self, arg: float, /) -> None: ...

    @property
    def top_k(self) -> int: ...

    @top_k.setter
    def top_k(self, arg: int, /) -> None: ...

    @property
    def seed(self) -> int | None: ...

    @seed.setter
    def seed(self, arg: int | None, /) -> None: ...

    @property
    def json_schema(self) -> str: ...

    @json_schema.setter
    def json_schema(self, arg: str, /) -> None: ...

    @property
    def stop(self) -> list[str]: ...

    @stop.setter
    def stop(self, arg: Sequence[str], /) -> None: ...

class GenerationResult:
    @property
    def text(self) -> str: ...

    @property
    def tokens(self) -> list[int]: ...

    @property
    def finish_reason(self) -> FinishReason: ...

    @property
    def prompt_tokens(self) -> int: ...

    @property
    def time_to_first_token_ms(self) -> float: ...

    @property
    def decode_tokens_per_second(self) -> float: ...

class TextGenerator:
    def __init__(self) -> None: ...

    def initialize(self, model_dir: str | os.PathLike, provider: ExecutionProvider = ExecutionProvider.CPU) -> None:
        """Load a GenAI model directory. Releases the GIL while the model loads."""

    def is_initialized(self) -> bool: ...

    def generate(self, messages: Sequence[tuple[str, str]], options: GenerationOptions = ..., on_text: object | None = None) -> GenerationResult:
        """
        Generate a reply to (role, content) messages; on_text receives each decoded piece. Releases the GIL.
        """

    def request_cancel(self) -> None:
        """
        End a running generate() after its current token; safe from any thread.
        """

class OnnxError(enum.Enum):
    SessionCreationFailed = 0

    ModelLoadFailed = 1

    InputAllocationFailed = 2

    OutputAllocationFailed = 3

    InferenceFailed = 4

    InvalidInputShape = 5

    InvalidInputType = 6

    MemoryAllocationError = 7

    SessionNotInitialized = 8

    OutputNotFound = 9

    InvalidOutputType = 10

    InvalidOutputShape = 11

    ProfilingNotEnabled = 12

    ProfilingFailed = 13

class ExecutionMode(enum.Enum):
    Sequential = 0

    Parallel = 1

class OnnxExecutionProvider(enum.Enum):
    Cpu = 0

    Cuda = 1

    MigraphX = 2

    DirectML = 3

class SessionConfig:
    def __init__(self) -> None: ...

    @property
    def model_path(self) -> pathlib.Path: ...

    @model_path.setter
    def model_path(self, arg: str | os.PathLike, /) -> None: ...

    @property
    def intra_op_num_threads(self) -> int: ...

    @intra_op_num_threads.setter
    def intra_op_num_threads(self, arg: int, /) -> None: ...

    @property
    def inter_op_num_threads(self) -> int: ...

    @inter_op_num_threads.setter
    def inter_op_num_threads(self, arg: int, /) -> None: ...

    @property
    def enable_cuda(self) -> bool: ...

    @enable_cuda.setter
    def enable_cuda(self, arg: bool, /) -> None: ...

    @property
    def enable_memory_pattern(self) -> bool: ...

    @enable_memory_pattern.setter
    def enable_memory_pattern(self, arg: bool, /) -> None: ...

    @property
    def execution_mode(self) -> ExecutionMode: ...

    @execution_mode.setter
    def execution_mode(self, arg: ExecutionMode, /) -> None: ...

    @property
    def execution_provider(self) -> OnnxExecutionProvider: ...

    @execution_provider.setter
    def execution_provider(self, arg: OnnxExecutionProvider, /) -> None: ...

    @property
    def device_id(self) -> int: ...

    @device_id.setter
    def device_id(self, arg: int, /) -> None: ...

def default_session_config(model_path: str | os.PathLike) -> SessionConfig:
    """Create a SessionConfig with sensible defaults for the given model."""

class InferenceResult:
    @property
    def outputs(self) -> list[object]:
        """List of NumPy arrays, one per model output."""

    @property
    def inference_time_ms(self) -> float: ...

class OnnxInferenceEngine:
    def __init__(self) -> None: ...

    def initialize(self, config: SessionConfig) -> None:
        """
        Load the model in config. Releases the GIL while the session is created.
        """

    def is_initialized(self) -> bool: ...

    def run_inference(self, input: Annotated[NDArray[numpy.float32], dict(order='C', device='cpu', writable=False)], input_name: str = 'input') -> InferenceResult:
        """
        Run inference on a float32 array; shape is taken from the array. Releases the GIL while running.
        """

    def run_inference_multi_input(self, inputs: dict) -> InferenceResult:
        """Run inference with a dict mapping input names to float32 arrays."""

    def get_input_names(self) -> list[str]: ...

    def get_output_names(self) -> list[str]: ...

    def get_input_shape(self, name: str) -> list[int]: ...

    def get_output_shape(self, name: str) -> list[int]: ...

class BoundingBox:
    def __init__(self) -> None: ...

    @property
    def x(self) -> float: ...

    @x.setter
    def x(self, arg: float, /) -> None: ...

    @property
    def y(self) -> float: ...

    @y.setter
    def y(self, arg: float, /) -> None: ...

    @property
    def width(self) -> float: ...

    @width.setter
    def width(self, arg: float, /) -> None: ...

    @property
    def height(self) -> float: ...

    @height.setter
    def height(self, arg: float, /) -> None: ...

    @property
    def confidence(self) -> float: ...

    @confidence.setter
    def confidence(self, arg: float, /) -> None: ...

    @property
    def class_id(self) -> int: ...

    @class_id.setter
    def class_id(self, arg: int, /) -> None: ...

    @property
    def class_name(self) -> str: ...

    @class_name.setter
    def class_name(self, arg: str, /) -> None: ...

    def __repr__(self) -> str: ...

class DetectionResult:
    @property
    def boxes(self) -> list[BoundingBox]: ...

    @property
    def class_confidences(self) -> list[float]: ...

    @property
    def inference_time_ms(self) -> float: ...

    @property
    def original_width(self) -> int: ...

    @property
    def original_height(self) -> int: ...

class YoloOutputLayout(enum.Enum):
    CenterObjectnessScores = 0

    CornersScoreClass = 1

class YoloConfig:
    def __init__(self) -> None: ...

    @property
    def model_path(self) -> pathlib.Path: ...

    @model_path.setter
    def model_path(self, arg: str | os.PathLike, /) -> None: ...

    @property
    def confidence_threshold(self) -> float: ...

    @confidence_threshold.setter
    def confidence_threshold(self, arg: float, /) -> None: ...

    @property
    def nms_threshold(self) -> float: ...

    @nms_threshold.setter
    def nms_threshold(self, arg: float, /) -> None: ...

    @property
    def input_width(self) -> int: ...

    @input_width.setter
    def input_width(self, arg: int, /) -> None: ...

    @property
    def input_height(self) -> int: ...

    @input_height.setter
    def input_height(self, arg: int, /) -> None: ...

    @property
    def num_classes(self) -> int: ...

    @num_classes.setter
    def num_classes(self, arg: int, /) -> None: ...

    @property
    def output_layout(self) -> YoloOutputLayout: ...

    @output_layout.setter
    def output_layout(self, arg: YoloOutputLayout, /) -> None: ...

    @property
    def execution_provider(self) -> OnnxExecutionProvider: ...

    @execution_provider.setter
    def execution_provider(self, arg: OnnxExecutionProvider, /) -> None: ...

    @property
    def device_id(self) -> int: ...

    @device_id.setter
    def device_id(self, arg: int, /) -> None: ...

class YoloDetector:
    def __init__(self) -> None: ...

    def initialize(self, config: YoloConfig) -> None:
        """
        Load the model in config. Releases the GIL while the session is created.
        """

    def is_initialized(self) -> bool: ...

    def detect(self, image: Annotated[NDArray[numpy.float32], dict(order='C', device='cpu', writable=False)], width: int = 0, height: int = 0) -> DetectionResult:
        """
        Detect in normalized RGB float32 CHW or single-batch NCHW. Width/height describe the original frame. Releases the GIL.
        """

    @staticmethod
    def get_coco_class_name(class_id: int) -> str: ...
