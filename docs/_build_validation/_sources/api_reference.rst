API Reference
=============

The API section is generated from Doxygen XML through Breathe and Exhale.

When the generated API files are available in this checkout, the full reference
is added under ``api/library_root`` in the built site.

If that page is missing, generate the API inputs first through the Linux docs
pipeline or a local configure plus Doxygen run that produces the expected XML.

Expected prerequisites:

- a configured build tree that emits ``build/Doxyfile``
- Doxygen XML under the path used by ``docs/source/conf.py``
- a docs build step that generates ``docs/source/api/library_root.rst``

Recommended path:

.. code-block:: bash

   bash scripts/linux/ci_docs.sh \
     --workspace-dir "$(pwd)" \
     --compiler clang \
     --runner ubuntu-24.04 \
     --docs-out build/build/html
