# Models

No model is tracked here. The default, `deim_dfine_n_coco.onnx` (DEIM-D-FINE-N, Apache-2.0,
COCO 80 classes), is built and released by [ModelANT](https://github.com/Kataglyphis/ModelANT).
`models.lock` pins it, its license and its notice by URL and SHA-256. Fetch them before running
the `AccelerANTgine_demo` program (`Src/inference_demo.cpp`) or
`resources/configs/inference_config.toml`'s default:

```bash
python3 -I third_party/ANTfrastructure/linux/scripts/lib/fetch-data-lock.py --lock models/models.lock
```

On Windows, `python` instead of `python3`. The
[hub's fetcher](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/data-repositories.md#the-hubs-fetcher)
puts the three files beside the lock and hashes each one. A download whose hash differs from the
lock fails the fetch (exit 1) and writes nothing; a file here that differs is replaced. Downloads
are cached by hash in `KATAGLYPHIS_MODEL_CACHE`, else in `kataglyphis-models` under `~/.cache`
(`%LOCALAPPDATA%` on Windows).

Ship `deim_dfine_n_coco.LICENSE` and `deim_dfine_n_coco.NOTICE` with the model. Its output is
`[1, 300, 6]`: x1, y1, x2, y2 in the 640x640 input's pixels, the score and the class.

`YoloDetector` reads that layout when `YoloConfig::output_layout` is
`YoloOutputLayout::CornersScoreClass`, as `Src/inference_demo.cpp` sets it. The default,
`CenterObjectnessScores`, is the YOLOv5 rows (cx, cy, w, h, objectness, one score per class).
