Windows Workflow
================

Build inside the Windows container, which synchronizes the artifacts back to the repository,
then run the built application and tests on the Windows host with PowerShell.

The package build selects ONNX Runtime's original license and notices from the image wheel
whose DLL matches the chain runtime byte for byte. The install tree, CPack ZIP and MSIX are
checked for both texts. Every other component of the DLL closure is listed, with its license
text, in ``licenses/THIRD-PARTY-NOTICES.txt``, which the ZIP, MSI and MSIX are checked for;
NSIS packs the same install tree but is not opened (:doc:`third_party_licenses`).

Build In The Container
----------------------

.. code-block:: powershell

   .\scripts\windows\Invoke-ContainerBuild.ps1

The wrapper delegates to ANTfrastructure's ``Invoke-ContainerBuild``
(``WindowsContainerBuild.Reuse``), which runs ``scripts/windows/Build-Windows.ps1`` inside a
reusable container:

- **Transport:** the sources travel by tar-pipe to the family workspace path ``C:\ws``. Bind
  mounting is the measured-slower opt-in (``-UseBindMount``); ``-FreshContainer`` discards the
  reused build tree.
- **Source selection:** both container wrappers pass exact and wildcard root exclusions to
  ANTfrastructure's runner. It selects top-level names without dropping a nested ``build``
  directory, and fails before Docker if no source entry remains.
- **Resources:** ``--isolation process`` gives the container every host CPU;
  ``-CpuCount``/``-MemoryGb`` apply only under ``-Isolation hyperv``.
- **Targets:** ``clangcl-debug``, ``clangcl-profile`` and ``clangcl-release``.
- **Delivery:** ``build-<target>`` (verified per lane), ``logs`` and ``dist`` come back to the
  host (`Artifact Locations`_).

Run The Build Script Directly
-----------------------------

Inside the image, the same script CI runs:

.. code-block:: powershell

   pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1
   pwsh -NoProfile -File .\scripts\windows\Build-Windows.ps1 -BuildTargets clangcl-debug -LogDir logs\debug

Build directories and presets are rows in
``scripts/windows/Build-Windows.config.psd1``, not parameters; each row also names
an environment variable that overrides it. ``-LogDir`` is relative to the
workspace. The script expects the family Windows image (its toolchain, its
GStreamer and its chain ONNX Runtime); from a host,
``.\scripts\windows\Invoke-ContainerBuild.ps1`` runs it inside that image.

Artifact Locations
------------------

The container build syncs its output back into the workspace, where the host-side scripts run
it directly:

- ``build-clangcl-debug``
- ``build-clangcl-profile``
- ``build-clangcl-release``
- ``dist\windows-x64`` for the release configuration's products: the portable
  ``bundle`` (the install tree with the engine's whole DLL closure), the MSI,
  ZIP and NSIS installers in ``packages``, and the MSIX in ``msix``
- ``logs`` for container build logs and analysis artifacts

Host-Side Execution
-------------------

``Start-Windows.ps1`` runs a configuration's executables outside the container. A missing or
unstartable binary fails the run; for one that exists but will not start, the script first walks
its imports and names every DLL the loader cannot find.

Debug Run
^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Debug

Starts the CLI from ``build-clangcl-debug\bin\AccelerANTgine.exe`` for a stable local version
check, then runs ``commitTestSuite.exe``, ``compileTestSuite.exe`` and ``fuzzTestSuite.exe`` (in
FuzzTest's unit mode, about a second per property).

With a signalling server already running on the host, opt into the network-dependent WebRTC
smoke test:

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Debug -RunWebRtcSmoke -ServerUri ws://localhost:8443

Profile Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Profile

Runs the profile build executable, then ``perfTestSuite.exe``; a missing suite fails the run.

Release Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Release

The CLI check, run from ``build-clangcl-release\bin`` (the build tree, not the ``dist``
bundle), then the Release suites ``Build-Windows.ps1 -StageTests`` staged in
``dist\windows-x64-tests``, through their ``Invoke-StagedTests.ps1``; a failed or an empty
verdict fails the run. Without staged suites it is the CLI check alone.

Build Script Responsibilities
-----------------------------

``scripts/windows/Build-Windows.ps1`` does more than compile:

- formats the CMake and C++ sources in place (``-SkipFormat`` skips both)
- configures preset-driven builds
- stages the image's GStreamer DLLs, the chain ONNX Runtime (proved by
  ANTfrastructure's G6 census) and the toolset's VC++ runtime beside each
  configuration's binaries
- runs debug tests with ``ctest``
- has an LLVM coverage step over ``Test\compile\default.profraw``, which finds
  nothing today: the ``x64-ClangCL-Windows-Debug`` preset leaves
  ``myproject_ENABLE_COVERAGE`` off
- runs ``clang-tidy``
- runs profile benchmarks
- builds release packages and the portable bundle in ``dist\windows-x64``
- optionally creates MSIX output (``-SkipMSIX`` skips it), signed with the first
  ``*.pfx`` at the repository root and ``MSIX_PFX_PASSWORD`` when there is one,
  and unsigned with a warning otherwise

The MSIX stage copies the project ``LICENSE`` beside the executable and checks the
finished archive with ANTfrastructure's shared package-license verifier. When MSIX
is selected, missing ``makeappx.exe``, the manifest or the project logo fails the
build; pass ``-SkipMSIX`` explicitly to omit this stage.

All three clang configurations call local ``Copy-BuildMediaRuntime``, which calls
ANTfrastructure's ``Copy-MediaRuntimeBundle`` with ``C:\runtime\bin`` as an extra
GStreamer root. Debug and Profile also stage test plugins and put chain ONNX Runtime
beside their root-level test suites; Release keeps its package-oriented layout.
The hub also considers
``GSTREAMER_BIN`` and refuses ONNX Runtime DLLs outside the chain install.
It also refuses ``DirectML.dll`` from a non-chain runtime root. A missing
GStreamer bin emits a warning; a host build can continue with chain ONNX Runtime.
The local ``Copy-ImageGStreamerTestPlugins`` stages only test plugins under
``lib\gstreamer-1.0``.

CI Note
-------

CI runs the same script, but not through ``Invoke-ContainerBuild.ps1``: both Windows lanes call
ANTfrastructure's reusable ``container-ci-windows.yml``, which bind-mounts the checkout
(``D:\ws`` on the runner, ``C:\ws`` in the container) and runs ``Build-Windows.ps1`` there. The
callers request direct submodules; the build needs no nested documentation tree, whose recursive
checkout can cycle through ANTfrastructure and DocumANTation. The
x64 lane then runs ``Start-Windows.ps1 -Config Debug|Profile|Release`` on the runner host, which
has the desktop the container lacks; the arm64 cross build runs on GitHub's ``windows-11-arm``
runner. Both lanes, their targets, artifacts and side jobs: ``AGENTS.md`` § 5.
