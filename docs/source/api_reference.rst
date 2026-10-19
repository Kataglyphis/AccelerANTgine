API Reference
=============

The API section is generated from Doxygen XML through Breathe and Exhale; the full reference
lives under ``api/library_root`` in the built site:

.. toctree::
   :maxdepth: 2

   api/library_root

That page needs the API inputs first:

- a configured build tree that emits ``build/Doxyfile``
- Doxygen XML under the path used by ``docs/source/conf.py``
- a docs build step that generates ``docs/source/api/library_root.rst``

Generate them through the Linux docs pipeline, ``scripts/linux/ci-docs.sh``
(:ref:`build-docs`), or a local configure plus Doxygen run that produces the expected XML.
