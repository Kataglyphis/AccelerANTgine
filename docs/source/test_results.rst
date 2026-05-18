Test Results
============

This section points to generated test and coverage artifacts when they are
available in the workspace.

Available outputs may include:

- converted JUnit result pages under ``docs/test-results``
- markdown conversions under ``docs/source/test-results``
- coverage HTML under ``docs/coverage``

The Linux docs pipeline is responsible for populating these generated assets.

Recommended path:

.. code-block:: bash

   bash scripts/linux/ci_run_all.sh \
     --compiler clang \
     --runner ubuntu-24.04 \
     --arch x64 \
     --build-type Debug \
     --build-dir build \
     --build-release-dir build-release

Direct links inside the built site:

- ``coverage/index.html`` for coverage reports
- ``test-results/`` for generated test result HTML
