Licenses And Third-Party Notices
================================

AccelerANTgine is MIT licensed (``LICENSE``). Every package also carries the license texts of the
open-source and redistributable components it contains, and a list that names each one.

What Each Package Carries
-------------------------

.. list-table::
   :header-rows: 1

   * - Package
     - Project license
     - Third-party list and texts
   * - Linux ``.deb``, ``.tar.gz``, AppImage, Flatpak
     - ``share/licenses/AccelerANTgine/LICENSE``
     - ``share/licenses/AccelerANTgine/THIRD-PARTY-NOTICES.txt`` and ``third-party/``;
       ONNX Runtime's own texts in ``share/licenses/onnxruntime/``
   * - Windows MSI, NSIS, ZIP
     - ``share/licenses/AccelerANTgine/LICENSE`` (and the WiX license page)
     - ``licenses/THIRD-PARTY-NOTICES.txt`` and ``licenses/third-party/``;
       ONNX Runtime's in ``licenses/onnxruntime/``
   * - Windows MSIX
     - ``LICENSE`` beside the executable
     - ``licenses/THIRD-PARTY-NOTICES.txt`` and ``licenses/third-party/``, copied from the bundle
   * - Python wheel
     - ``kataglyphis_inference/licenses/LICENSE`` and the wheel's ``dist-info/licenses/LICENSE``
     - ``kataglyphis_inference/licenses/THIRD-PARTY-NOTICES.txt``

Each list gives, per component: name, version, SPDX license, homepage, the source the binaries were
built from (copyleft components), the shipped files and the license text paths, relative to the
installation root. ``third-party-inventory.json`` beside it holds the same data for tools.

How The List Is Made
--------------------

``cmake/ThirdPartyNotices.cmake`` adds an install step that runs
``scripts/packaging/third_party_notices.py`` over the tree being installed, so every CPack generator,
the Flatpak and the Windows install proof get the list of exactly what they pack:

- **Inventory:** ``packaging/third-party/components.json`` names every component that is not a
  distribution package, with file-name patterns, its SPDX expression and where its texts come from.
  The first matching entry wins, so specific patterns precede broad ones. Versions come from
  ANTfrastructure's ``versions.env`` where the image pins them.
- **Tracked texts:** ``packaging/third-party/texts/`` holds the texts that no build input carries:
  LGPL-2.1, GPL-3.0 with the GCC Runtime Library Exception, MPL-2.0, ORC's and libffi's licenses,
  and the Rust standard library's MIT and Apache-2.0 texts.
- **Debian packages:** on Linux, a bundled library that the closure found in a Debian package's
  files is listed under that package, with its ``/usr/share/doc/<package>/copyright`` and every
  ``/usr/share/common-licenses`` text the copyright file cites. The lookup searches the closure's
  directories in the closure's order, the compiler's runtime directory first.
- **ONNX Runtime:** on Windows its ``LICENSE`` and ``ThirdPartyNotices.txt`` come from the image
  wheel whose DLL matches the shipped one (``Copy-OrtWheelLicenses``). On Linux
  ``scripts/packaging/stage_ort_texts.py`` first proves the bundled library is the chain build's,
  then takes the chain build's own ``licenses/`` (images built after ANTfrastructure ca303de0), else
  a byte-identical wheel (``stage-ort-wheel-licenses.py``), else, with a ``WARN`` line, the chain
  wheels of the same ONNX Runtime version, which must all carry the same texts. The chain C library
  and the chain wheel are separate builds of one checkout, so today's image needs the last case.
- **Rust crates:** ANTfrastructure's ``stage-cargo-licenses.py`` collects the original license files
  of ``Src/rusty_code``'s Cargo graph offline; ``packaging/third-party/cargo-license-policy.json``
  reviews the one crate with an ``AND`` expression. The graph includes the build-time ``cxx``
  macro crates, so the list is conservative.

**The step fails the install** when a shipped binary matches neither the project, the inventory nor
a Debian package, when a text is missing or empty, or when a version variable is undefined. A new
dependency therefore fails the package build until it is added to the inventory.

How The Packages Are Checked
----------------------------

- Linux: ``ci-release.sh`` installs the tree once more and checks that every ``.deb``,
  ``.tar.gz``, Flatpak and AppImage carries the same notices, the project license and ONNX
  Runtime's two texts (ANTfrastructure's ``verify_package_license.py`` and
  ``verify-native-appimage-license.sh``), and the project logo as the 256 px PNG and the scalable SVG
  icon, byte for byte against ``images/``.
- Windows: ``Build-Windows.ps1`` checks the notices in every ZIP and MSI and in the MSIX
  (``Assert-PackageLicense``, ``Assert-MsiPackageLicense``). NSIS packs the same install tree but
  is not opened.
- ``scripts/linux/tests/test-third-party-notices.sh`` (lint-gates lane) runs the stager on
  synthetic Windows, Linux and wheel trees; ``ThirdPartyNoticesWiring.Tests.ps1`` checks the
  Windows and CMake wiring.

Known Gaps
----------

- **DirectML and the Visual C++ runtime** are listed with a notice and the URL of Microsoft's
  terms; the Windows image carries neither text.
- **gst-plugins-rs** (``rswebrtc``, ``rsrtp``) is listed under MPL-2.0; the Rust crates it links
  statically are not itemized, because the image does not keep its Cargo license inventory.
- ``Build-PythonBindings.ps1`` stages a Windows Python package directory with every GStreamer DLL;
  that directory gets no notice list.
