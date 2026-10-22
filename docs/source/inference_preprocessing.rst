Inference and preprocessing
===========================

``YoloDetector::detect_frame`` accepts a ``gstreamer::BufferInfo``, converts its pixels to the
model input and maps detections back to the original frame. ``detect_from_gstreamer`` and
``VideoDetectorPipeline`` both use this path. ``detect`` is the lower-level interface for
callers that already have normalized RGB NCHW floats; its width and height describe the
original image for stretch coordinate mapping.

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
right or bottom. ``PreprocessedFrame::mapping`` records the actual per-axis scale and padding;
``detect_frame`` uses it to undo padding and scaling when decoding boxes. Use this frame path
when letterbox coordinate mapping is needed.

The model's export determines both preprocessing and output layout. For ModelANT's
DEIM-D-FINE-N choose stretch and ``YoloOutputLayout::CornersScoreClass``: its rows are
``x1, y1, x2, y2, score, class`` in model-input pixels. The legacy
``CenterObjectnessScores`` layout remains the default for callers using that YOLO export.
These configuration choices are explicit; the detector does not infer them from a byte count.

Shared reference cases
----------------------

``third_party/ModelANT/contracts/inference-v1.json`` defines input names, dtype, channel order,
sampling, resize modes, padding, expected NCHW tensors and coordinate mappings. The C++ suite
embeds the pinned JSON at configure time and runs its cases through production
``preprocess_frame``. Python and Rust consume the same data. Expected values are not generated
by another copy of the backend under test.

ModelANT owns this contract and its fixture licensing. The ModelANT submodule supplies small
test data; weights, LICENSE and NOTICE are still fetched through ``models/models.lock``.
See `ModelANT's contract documentation
<https://github.com/Kataglyphis/ModelANT/blob/7bb8c9f5b4c8a74632c850b0066dc8ec2adf421f/contracts/README.md>`_ and
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
letterbox mapping, shared ModelANT cases, real ``videotestsrc`` frame dimensions and asynchronous
failure reporting. ONNX tests generate unsupported output kinds and types without downloading
model weights.

Run the suite in the family image:

.. code-block:: bash

   cmake --preset linux-debug-clang
   cmake --build --preset linux-debug-clang --target commitTestSuite
   ctest --test-dir build --no-tests=error --output-on-failure -R 'FramePreprocessing|YoloDetector|Onnx'

When changing bound errors or inference behavior, also run the bindings suite against a built
package, as described in :doc:`getting_started`.
