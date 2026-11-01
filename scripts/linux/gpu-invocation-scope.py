#!/usr/bin/env python3
"""Validate a reusable GPU workflow invocation scope and emit its suffix."""

import os
import re
from pathlib import Path


def main() -> None:
    scope = os.environ.get("GPU_INVOCATION_SCOPE", "default")
    if re.fullmatch(r"[a-z][a-z0-9-]{0,31}", scope, flags=re.ASCII) is None:
        raise ValueError(
            "invocation scope must be 1–32 lowercase letters, digits or hyphens and start with a letter"
        )
    suffix = "" if scope == "default" else f"-scope-{scope}"
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write(f"suffix={suffix}\n")


if __name__ == "__main__":
    main()
