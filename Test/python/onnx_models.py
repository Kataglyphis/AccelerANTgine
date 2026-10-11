"""Hand-encoded ONNX models for the binding tests, the Python twin of Test/common/kataglyphis_test_support.h."""

from __future__ import annotations

ONNX_FLOAT = 1
ONNX_INT64 = 7


def _varint(value: int) -> bytes:
    out = bytearray()
    value &= (1 << 64) - 1
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _key(field: int, wire_type: int) -> bytes:
    return _varint((field << 3) | wire_type)


def _int(field: int, value: int) -> bytes:
    return _key(field, 0) + _varint(value)


def _bytes(field: int, value: bytes | str) -> bytes:
    raw = value.encode() if isinstance(value, str) else value
    return _key(field, 2) + _varint(len(raw)) + raw


def _value_info(name: str, dims: list[int]) -> bytes:
    shape = b"".join(_bytes(1, _int(1, d)) for d in dims)
    tensor_type = _int(1, ONNX_FLOAT) + _bytes(2, shape)
    return _bytes(1, name) + _bytes(2, _bytes(1, tensor_type))


def build_model(
    inputs: list[tuple[str, list[int]]],
    outputs: list[tuple[str, list[int]]],
    nodes: list[tuple[str, list[str], list[str]]],
    constants: tuple[tuple[str, list[int]], ...] = (),
) -> bytes:
    """ModelProto (IR 8, opset 13): float inputs/outputs and 1-D int64 initializers."""
    graph = b""
    for index, (op_type, node_inputs, node_outputs) in enumerate(nodes):
        node = b"".join(_bytes(1, i) for i in node_inputs) + b"".join(_bytes(2, o) for o in node_outputs)
        node += _bytes(3, f"{op_type}_{index}") + _bytes(4, op_type)
        graph += _bytes(1, node)
    graph += _bytes(2, "kataglyphis_test_graph")
    for name, values in constants:
        packed = b"".join(_varint(v) for v in values)
        graph += _bytes(5, _int(1, len(values)) + _int(2, ONNX_INT64) + _bytes(7, packed) + _bytes(8, name))
    graph += b"".join(_bytes(11, _value_info(n, d)) for n, d in inputs)
    graph += b"".join(_bytes(12, _value_info(n, d)) for n, d in outputs)
    return _int(1, 8) + _bytes(2, "kataglyphis-test") + _bytes(7, graph) + _bytes(8, _int(2, 13))


def relu_model() -> bytes:
    """X[1,4] -> Relu -> Y[1,4]."""
    return build_model([("X", [1, 4])], [("Y", [1, 4])], [("Relu", ["X"], ["Y"])])


def yolo_reshape_model(height: int, width: int, rows: int, values: int) -> bytes:
    """images[1,3,H,W] reshaped to output[1,rows,values]: the input is the raw detector output."""
    return build_model(
        [("images", [1, 3, height, width])],
        [("output", [1, rows, values])],
        [("Reshape", ["images", "shape"], ["output"])],
        (("shape", [1, rows, values]),),
    )
