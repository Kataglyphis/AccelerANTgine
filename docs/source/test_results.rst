Test Results
============

This section points to generated test and coverage artifacts when they are
available in the workspace.

Available outputs may include:

- one page per JUnit report the test step writes (``docs/test_results*.xml``),
  rendered by ``scripts/linux/junit_to_markdown.py`` into
  ``docs/source/test-results``
- coverage HTML under ``docs/coverage``

The Linux docs pipeline is responsible for populating these generated assets.

Recommended path:

.. code-block:: bash

   bash scripts/linux/ci-run-all.sh \
     --compiler clang \
     --runner ubuntu-26.04 \
     --arch x64 \
     --build-type Debug \
     --build-dir build \
     --build-release-dir build-release

Direct links inside the built site:

- ``coverage/index.html`` for coverage reports
- :doc:`test-results/index` for the test result pages
