"""Python bindings for the Kataglyphis C++ ONNX inference engine."""

import os as _os

# Python 3.8+ on Windows ignores PATH for extension DLLs; KATAGLYPHIS_DLL_PATH adds extra directories.
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

from . import _core
from ._core import *

__doc__ = _core.__doc__
__version__ = _core.__version__
