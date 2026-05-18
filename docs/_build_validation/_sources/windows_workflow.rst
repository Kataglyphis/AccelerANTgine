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

   .\scripts\windows\start_build.ps1

This script runs Docker with the repository mounted into ``C:\workspace`` and
executes ``scripts/windows/Build-Windows.ps1`` inside the container.

Local resource settings in the wrapper are:

- ``--cpus 32``
- ``--memory 48g``

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
- ``logs`` for container build logs and analysis artifacts

Host-Side Execution
-------------------

After the build finishes, run the executables outside the container.

Debug Run
^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\start_debug.ps1

This script:

- starts the CLI from ``build-clangcl-debug\bin\KataglyphisCppInference.exe``
- performs a stable local CLI version check by default
- runs ``commitTestSuite.exe`` when present
- runs ``compileTestSuite.exe`` when present
- reports the presence of ``first_fuzz_test.exe``

For a host machine that already has a signalling server running, you can opt into
the older network-dependent smoke test explicitly:

.. code-block:: powershell

   .\scripts\windows\start_debug.ps1 -RunWebRtcSmoke -ServerUri ws://localhost:8443

Profile Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\start_profile.ps1

This script runs the profile build executable and then executes
``perfTestSuite.exe`` when available.

Release Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\start_release.ps1

This is the lightest validation path for release artifacts and packaged runtime
output.

Build Script Responsibilities
-----------------------------

``scripts/windows/Build-Windows.ps1`` does more than compile:

- configures preset-driven builds
- runs debug tests with ``ctest``
- collects LLVM coverage artifacts when available
- runs ``clang-tidy``
- runs profile benchmarks
- builds release packages
- optionally creates MSIX output

CI Note
-------

The Windows GitHub Actions workflow now follows the same model as local usage:

- build inside the Windows container through ``start_build.ps1``
- request ``48g`` memory and ``32`` CPUs for the Docker run
- execute ``start_debug.ps1``, ``start_profile.ps1``, and ``start_release.ps1``
  on the host after the container build completes

Whether the hosted runner can always satisfy those Docker resource requests still
depends on the runner environment.
