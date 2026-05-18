Development Workflow
====================

This project works best when features, tests, documentation, and refactors are
shipped together in small, verifiable slices.

Recommended Loop
----------------

1. Define the smallest useful feature increment.
2. Implement the behavior in ``Src/``.
3. Add or extend the matching test coverage.
4. Update Sphinx documentation in the same change.
5. Refactor the touched area only after the behavior is covered.
6. Validate with the appropriate local script or preset.

Documentation Rule
------------------

Every non-trivial feature should update the Sphinx project accordingly.

Typical updates:

- ``getting_started`` when user-facing setup or runtime usage changes
- ``overview`` when architecture or capability boundaries change
- a new dedicated page when the feature needs operational guidance,
  examples, or design notes

Test Strategy
-------------

The repository already contains multiple test layers.

Unit And Regression Tests
^^^^^^^^^^^^^^^^^^^^^^^^^

- Add logic-focused coverage to the debug suites in ``Test/compile`` and
  ``Test/commit``
- Prefer small deterministic tests for library behavior and boundary cases

Integration Tests
^^^^^^^^^^^^^^^^^

Add integration coverage when a change spans:

- CLI to library interactions
- optional dependency discovery
- packaging/runtime path behavior
- C API to library boundaries

Fuzz Tests
^^^^^^^^^^

Use ``Test/fuzz`` for inputs that are difficult to enumerate manually, such as:

- configuration files
- CLI argument combinations
- parser inputs
- externally provided model metadata or request payloads

Performance Tests
^^^^^^^^^^^^^^^^^

Use ``Test/perf`` for changes that claim measurable runtime impact, such as:

- inference startup time
- repeated execution performance
- pipeline setup costs
- serialization or preprocessing hot paths

Refactoring Cadence
-------------------

Periodic refactoring is encouraged, but it should stay grounded in tested code.

Prefer refactors that:

- reduce duplication in frequently touched code paths
- clarify runtime or dependency boundaries
- simplify test setup
- improve naming and control flow without changing behavior

Avoid broad cleanup passes that are not tied to active work unless there is
clear payoff and sufficient coverage.

Validation Targets
------------------

Choose the smallest validation path that still proves the change.

- Linux debug correctness: ``cmake --preset linux-debug-clang``
- Linux TSan validation: ``cmake --preset linux-debug-clang-tsan``
- Linux profile benchmarks: ``cmake --preset linux-profile-clang``
- Windows debug/profile/release container builds: ``.\scripts\windows\start_build.ps1``
- Windows host execution: ``.\scripts\windows\start_debug.ps1``,
  ``.\scripts\windows\start_profile.ps1``, ``.\scripts\windows\start_release.ps1``

CI Alignment
------------

The GitHub workflows are the reference for how the project is expected to build
and validate:

- Linux workflows orchestrate build, tests, coverage, analysis, docs, and release
- Windows workflow builds inside the project container and uploads packaged artifacts

When adding features, keep local verification aligned with those same paths so
CI remains a confirmation step rather than a discovery step.
