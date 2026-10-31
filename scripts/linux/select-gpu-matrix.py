#!/usr/bin/env python3
"""Select only supported Linux GPU package and runner combinations."""

import json
import os
from pathlib import Path

ROWS = {
    "nvidia-x64": {
        "vendor": "nvidia",
        "arch": "x64",
        "tag": "latest-nvidia",
        "platform": "linux/amd64",
        "runner": "ubuntu-26.04",
        "runner-arch": "X64",
        "gpu-runner": "gpu-nvidia-cuda",
        "device": "cuda",
    },
    "nvidia-arm64": {
        "vendor": "nvidia",
        "arch": "arm64",
        "tag": "latest-nvidia",
        "platform": "linux/arm64",
        "runner": "ubuntu-26.04-arm",
        "runner-arch": "ARM64",
        "gpu-runner": "gpu-nvidia-cuda",
        "device": "cuda",
    },
    "amd-x64": {
        "vendor": "amd",
        "arch": "x64",
        "tag": "latest-rocm",
        "platform": "linux/amd64",
        "runner": "ubuntu-26.04",
        "runner-arch": "X64",
        "gpu-runner": "gpu-amd-rocm",
        "device": "migraphx",
    },
}


def main():
    selected = os.environ["GPU_TUPLE"]
    if selected == "all":
        rows = list(ROWS.values())
    elif selected in ROWS:
        rows = [ROWS[selected]]
    else:
        raise ValueError(
            "unsupported Linux GPU tuple; expected all, nvidia-x64, nvidia-arm64 or amd-x64"
        )
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as out:
        out.write(
            "matrix=" + json.dumps({"include": rows}, separators=(",", ":")) + "\n"
        )


if __name__ == "__main__":
    main()
