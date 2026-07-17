"""Python bindings for the Kataglyphis C++ ONNX inference engine."""

import os as _os

# The extension module links against KataglyphisCppInference (and, depending on
# the build, ONNX Runtime / GStreamer DLLs). The core DLL ships inside this
# package; extra runtime DLL directories can be supplied via KATAGLYPHIS_DLL_PATH.
if hasattr(_os, "add_dll_directory"):
    _pkg_dir = _os.path.dirname(_os.path.abspath(__file__))
    _os.add_dll_directory(_pkg_dir)
    # Bundled third-party runtime DLLs (GStreamer, ONNX Runtime), if staged.
    _libs_dir = _os.path.join(_pkg_dir, "_libs")
    if _os.path.isdir(_libs_dir):
        _os.add_dll_directory(_libs_dir)
    for _extra in _os.environ.get("KATAGLYPHIS_DLL_PATH", "").split(_os.pathsep):
        if _extra and _os.path.isdir(_extra):
            _os.add_dll_directory(_extra)

from ._core import *  # noqa: F401,F403
from ._core import __doc__, __version__  # noqa: F401
