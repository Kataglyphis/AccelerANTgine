Inference and preprocessing
===========================

``YoloDetector::detect_frame`` accepts a ``gstreamer::BufferInfo``, converts its pixels to the
model input and maps detections back to the original frame. ``detect_from_gstreamer`` and
``VideoDetectorPipeline`` both use this path. ``detect`` is the lower-level interface for
callers that already have normalized RGB NCHW floats; its width and height describe the
original image for stretch coordinate mapping.

The Python ``YoloDetector.detect`` binding accepts contiguous float32 RGB tensors in ``[3, H, W]``
or ``[1, 3, H, W]`` order. If the original frame dimensions differ from the input tensor,
pass both ``width`` and ``height`` to map boxes to that frame. When omitted, they default to
the tensor's spatial dimensions. Flattened arrays remain supported with both dimensions explicit;
the binding does not convert interleaved HWC pixels or normalize byte values.

Frame memory
------------

The frame metadata must name ``RGB`` or ``RGBA`` and nonzero width and height. Alpha is ignored.
``row_stride_bytes`` describes the distance between row starts; zero means tightly packed rows.
``plane_offset_bytes`` locates the first pixel in ``BufferInfo::data``. GStreamer extraction
reads these values from video information and uses per-buffer video metadata when present.

The conversion checks row length, offset, available bytes and size arithmetic before reading.
Negative stride, incomplete buffers and zero dimensions return ``InvalidInputShape``;
unsupported pixel formats return ``InvalidInputType``. A padded RGB row must not be treated as
``width * 3`` bytes, and a buffer of bytes must never be reinterpreted as a float tensor.

Resize and mapping
------------------

``YoloConfig::preprocess_mode`` selects ``FramePreprocessMode::Stretch`` (the default) or
``FramePreprocessMode::Letterbox``. Both sample with nearest-neighbour floor indexing, divide
RGB bytes by 255 and produce ``[1, 3, input_height, input_width]`` in NCHW order.

Stretch resizes each axis independently. Letterbox preserves aspect ratio, rounds and clamps
the resized dimensions, then pads with ``114/255``. Integer padding puts an extra pixel on the
right or bottom. ``PreprocessedFrame::mapping`` records the frame's size and the actual per-axis
scale and padding; ``detect_frame`` hands it to the decoder, which undoes padding and scaling and
cuts each box to that frame. Use this frame path when letterbox coordinate mapping is needed.

The model's export determines both preprocessing and output layout. For ModelANT's
DEIM-D-FINE-N choose stretch and ``YoloOutputLayout::CornersScoreClass``: its rows are
``x1, y1, x2, y2, score, class`` in model-input pixels. The legacy
``CenterObjectnessScores`` layout remains the default for callers using that YOLO export.
These configuration choices are explicit; the detector does not infer them from a byte count.
``initialize`` holds them to the model: a model whose ``kataglyphis.preprocess`` names the other
fitting, or whose ``kataglyphis.output`` names another layout, fails at the start with both names
in the log.

The camera factory keeps one frame at most between capture and the detector (a leaky queue and
``appsink max-buffers=1 drop=true``), so a detector slower than the camera sees the newest
frame, not a growing backlog. ``detect_frame`` runs the model on its own preprocessed buffer
through ``OnnxInferenceEngine::run_inference_in_place``, which skips the copy ``run_inference``
makes of a read-only input.

Decoding
--------

``decode_detections(output, config, mapping)`` is the one function from a model's raw output to
boxes in frame pixels; ``detect`` and ``detect_frame`` call it and add nothing to its boxes.

- ``FrameMapping`` says how the frame was fitted into the input (``scale_x``, ``scale_y``,
  ``pad_x``, ``pad_y``) and names the frame (``frame_width``, ``frame_height``).
  ``preprocess_frame`` and ``detect`` fill it. A mapping whose frame size is zero, the default, is
  ``InvalidInputShape``: the decoder has no edge to cut at, so it refuses the call.
- A corner row (``CornersScoreClass``) is a box only with a finite score of at least the
  threshold, a class from 0 up to, not including, ``num_classes`` (the number cut to an integer)
  and finite corners in order; a point stays. Corner rows are never suppressed.
- The two raw layouts suppress overlaps of one class at ``nms_threshold`` first.
- Every box is then mapped back, ``(x - pad_x) / scale_x`` and ``(y - pad_y) / scale_y``, and cut
  to the frame: x into ``[0, frame_width]``, y into ``[0, frame_height]``. The raw layouts are cut
  after suppression, so two boxes that only become alike at the frame's edge both stay.

Shared reference cases
----------------------

``third_party/ModelANT/contracts/inference-v1.json`` defines input names, dtype, channel order,
sampling, resize modes, padding, expected NCHW tensors and coordinate mappings, and under
``decode`` its five rules for ``xyxy_score_class`` rows, which the section above restates, with
cases of raw rows and the detections they give. The C++ suite embeds the pinned JSON at
configure time. It runs the preprocessing cases through production ``preprocess_frame`` and
every decode case through ``decode_detections``, comparing the list in row order within the
contract's tolerances; a case ModelANT appends is replayed without an edit here. Python and Rust
consume the same data. Expected values are not generated by another copy of the backend under
test.

``kataglyphis_embed_text_file`` writes an embedded file as a char array, one char per byte, not
as a string literal: MSVC refuses a literal over 16380 bytes, and the contract grows with every
case. A path was not an option: the staged Windows suites run on another machine than the one
that built them.

ModelANT owns this contract and its fixture licensing. The ModelANT submodule supplies small
test data; weights, LICENSE and NOTICE are still fetched through ``models/models.lock``.
See `ModelANT's contract documentation
<https://github.com/Kataglyphis/ModelANT/blob/a6eaca189b72d257700511f856ccfe9407350626/contracts/README.md>`_ and
`the model download guide <https://github.com/Kataglyphis/AccelerANTgine/blob/develop/models/README.md>`_.

Output and error handling
-------------------------

``OnnxInferenceEngine`` returns dense FLOAT tensors. It checks the ONNX value kind, element
type, dimensions and data pointer before copying output storage. Integer, byte, boolean,
sequence, map and other unsupported outputs return ``InvalidOutputType``. Invalid dimensions
return ``InvalidOutputShape``; a failed data access returns ``OutputAllocationFailed``.
Single-input and multi-input inference propagate these errors through ``std::expected``.
The Python bindings export the new error names and report failed operations as exceptions.

For asynchronous video, register ``VideoDetectorPipeline::set_error_callback`` to receive
failed-frame errors and inspect ``last_error()`` for the most recent failure. Callbacks run on
the streaming thread. ``start()`` clears the stored error; subsequent successful frames do not.
Without a callback, a changed error is printed to stderr instead of being silently discarded.

Validation
----------

The commit suite covers padded RGB rows, plane offsets, channel order, normalization,
letterbox mapping, the shared ModelANT preprocessing and decode cases, the cut to the frame for
every layout, real ``videotestsrc`` frame dimensions and asynchronous failure reporting. ONNX
tests generate unsupported output kinds and types without downloading model weights.

Run the suite in the family image:

.. code-block:: bash

   cmake --preset linux-debug-clang
   cmake --build --preset linux-debug-clang --target commitTestSuite
   ctest --test-dir build --no-tests=error --output-on-failure -R 'FramePreprocessing|YoloDetector|YoloDecoder|Onnx'

When changing bound errors or inference behavior, also run the bindings suite against a built
package, as described in :doc:`getting_started`.
