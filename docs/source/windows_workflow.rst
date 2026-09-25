Windows Workflow
================

The intended Windows developer flow is:

1. build inside the Windows container
2. synchronize artifacts back to the repository
3. run the built application and tests on the Windows host with PowerShell

Build In The Container
----------------------

Use the wrapper script:

.. code-block:: powershell

   .\scripts\windows\Invoke-ContainerBuild.ps1

This script delegates to ANTfrastructure's ``Invoke-ContainerBuild``
(``WindowsContainerBuild.Reuse``): the sources travel by tar-pipe into a
reusable container at the family workspace path ``C:\ws`` and
``scripts/windows/Build-Windows.ps1`` runs inside it. Bind mounting is the
measured-slower opt-in (``-UseBindMount``); ``-FreshContainer`` discards the
reused build tree.

Resource settings: ``--isolation process`` gives the container every host CPU;
``-CpuCount``/``-MemoryGb`` apply only under ``-Isolation hyperv``.

The container build currently targets:

- ``clangcl-debug``
- ``clangcl-profile``
- ``clangcl-release``

Artifact Locations
------------------

The container build syncs output back into the workspace so host-side scripts can
run them directly.

- ``build-clangcl-debug``
- ``build-clangcl-profile``
- ``build-clangcl-release``
- ``dist\windows-x64`` for the release configuration's products: the portable
  ``bundle`` (the install tree with the engine's whole DLL closure), the MSI,
  ZIP and NSIS installers in ``packages``, and the MSIX in ``msix``
- ``logs`` for container build logs and analysis artifacts

Host-Side Execution
-------------------

After the build finishes, run the executables outside the container.

Debug Run
^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Debug

This script:

- starts the CLI from ``build-clangcl-debug\bin\AccelerANTgine.exe``
- performs a stable local CLI version check by default
- runs ``commitTestSuite.exe`` and ``compileTestSuite.exe``
- reports the presence of ``first_fuzz_test.exe`` without running it

A missing or unstartable binary fails the run. For one that exists but will not
start, the script first walks its imports and names every DLL the loader cannot
find.

For a host machine that already has a signalling server running, you can opt into
the older network-dependent smoke test explicitly:

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Debug -RunWebRtcSmoke -ServerUri ws://localhost:8443

Profile Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Profile

This script runs the profile build executable and then executes
``perfTestSuite.exe``; a missing suite fails the run.

Release Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Windows.ps1 -Config Release

This is the lightest validation path: the CLI check alone, run from
``build-clangcl-release\bin`` (the build tree, not the ``dist`` bundle).

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

CI Note
-------

CI runs the same script, but not through ``Invoke-ContainerBuild.ps1``.
``.github/workflows/windows-x64.yml`` is a thin caller of ANTfrastructure's
reusable ``container-ci-windows.yml``, which bind-mounts the checkout (``D:\ws``
on the runner, ``C:\ws`` in the container) and runs ``Build-Windows.ps1`` there
for ``clangcl-debug``, ``clangcl-profile`` and ``clangcl-release``. Its host
command then runs ``Start-Windows.ps1 -Config Debug|Profile|Release`` on the
runner host, which has the desktop the container lacks, and
``dist/windows-x64`` uploads as the ``AccelerANTgine-windows-x64`` artifact. Two
jobs beside it lint ``scripts/`` (the hub's ``Invoke-Lint.ps1``) and run the
Pester suites in ``scripts/windows/tests``.

``.github/workflows/windows-arm64-cross.yml`` calls the same reusable workflow
for ``clangcl-release`` only, with ``-TargetArch arm64``: a cross build in the
image's arm64 bundle, graded by the hub's arch gate, whose
``bundle/bin/AccelerANTgine.exe`` then runs on GitHub's ``windows-11-arm``
runner.
