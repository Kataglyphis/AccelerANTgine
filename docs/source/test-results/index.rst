:orphan:

Test Results
============

Before Sphinx runs, ``scripts/linux/ci-docs.sh`` renders each JUnit report the
test step wrote (``docs/test_results*.xml``) into a page in this folder, with
``scripts/linux/junit_to_markdown.py``; a build that found no report gets a page
saying so. The pages are listed below.

.. toctree::
   :maxdepth: 1
   :glob:

   *
