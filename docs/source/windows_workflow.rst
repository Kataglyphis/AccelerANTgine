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

   .\scripts\windows\Start-Build.ps1

This script delegates to ContainerHub's ``Invoke-ContainerBuild``
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
- ``logs`` for container build logs and analysis artifacts

Host-Side Execution
-------------------

After the build finishes, run the executables outside the container.

Debug Run
^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Debug.ps1

This script:

- starts the CLI from ``build-clangcl-debug\bin\AccelerANTgine.exe``
- performs a stable local CLI version check by default
- runs ``commitTestSuite.exe`` when present
- runs ``compileTestSuite.exe`` when present
- reports the presence of ``first_fuzz_test.exe``

For a host machine that already has a signalling server running, you can opt into
the older network-dependent smoke test explicitly:

.. code-block:: powershell

   .\scripts\windows\Start-Debug.ps1 -RunWebRtcSmoke -ServerUri ws://localhost:8443

Profile Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Profile.ps1

This script runs the profile build executable and then executes
``perfTestSuite.exe`` when available.

Release Run
^^^^^^^^^^^

.. code-block:: powershell

   .\scripts\windows\Start-Release.ps1

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

- build inside the Windows container through ``Start-Build.ps1``
- pass ``-CpuCount 32 -MemoryGb 48`` — effective only under ``-Isolation
  hyperv``; the default ``process`` isolation gives the container every host
  CPU regardless
- execute ``Start-Debug.ps1``, ``Start-Profile.ps1``, and ``Start-Release.ps1``
  on the host after the container build completes

Whether the hosted runner can always satisfy those Docker resource requests still
depends on the runner environment.
