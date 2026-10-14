# Models

No model is tracked here. The default, `deim_dfine_n_coco.onnx` (DEIM-D-FINE-N, Apache-2.0,
COCO 80 classes), is built and released by [ModelANT](https://github.com/Kataglyphis/ModelANT).
Fetch it and check its SHA-256 before running `Src/inference_demo.cpp` or
`resources/configs/inference_config.toml`'s default:

```bash
base=https://github.com/Kataglyphis/ModelANT/releases/download/deim_dfine_n_coco-v1
curl -fL -o models/deim_dfine_n_coco.onnx "$base/deim_dfine_n_coco.onnx"
echo "225f612fc879d604b79a569648f274672090070a07dcbdef469796df956f8392  models/deim_dfine_n_coco.onnx" | sha256sum -c
```

Its license and notice are `deim_dfine_n_coco.LICENSE` and `deim_dfine_n_coco.NOTICE` in the
same release; ship both with the model. Its output is `[1, 300, 6]`: x1, y1, x2, y2 in the
640x640 input's pixels, the score and the class.

**`YoloDetector` does not read that layout yet.** Its decoder takes the YOLOv5 rows (cx, cy, w,
h, objectness, class scores), which neither this model nor the YOLO26n it replaced emit; the
tests feed it generated models in that layout (`Test/common/kataglyphis_test_support.h`).
