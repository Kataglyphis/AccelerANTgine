API Reference
=============

The API section is generated from Doxygen XML through Breathe and Exhale.

The full reference lives under ``api/library_root`` in the built site:

.. toctree::
   :maxdepth: 2

   api/library_root

If that page is missing, generate the API inputs first through the Linux docs
pipeline or a local configure plus Doxygen run that produces the expected XML.

Expected prerequisites:

- a configured build tree that emits ``build/Doxyfile``
- Doxygen XML under the path used by ``docs/source/conf.py``
- a docs build step that generates ``docs/source/api/library_root.rst``

Recommended path:

.. code-block:: bash

   bash scripts/linux/ci-docs.sh \
     --workspace-dir "$(pwd)" \
     --compiler clang \
     --runner ubuntu-26.04 \
     --docs-out build/build/html
