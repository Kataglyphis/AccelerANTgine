Text generation
===============

``kataglyphis.text_generation`` runs language models on ONNX Runtime GenAI, the chain build in the
family's images. It follows the shared text contract of
`ANTfrastructure's language-ai.md <https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/language-ai.md>`__:
messages in, decoded text out as it is generated, a cancel from any thread, and speed figures.
The same calls are reachable from C++, C, Python and the CLI.

Loading
-------

The module compiles against GenAI's C header, found by ``cmake/SystemLibDependencies.cmake`` under
``ONNXRUNTIME_GENAI_ROOT``, ``ONNX_GENAI_ROOT`` on Windows, or ``/usr/local/lib/onnxruntime-genai``.
It loads ``libonnxruntime-genai.so`` or ``onnxruntime-genai.dll`` at run time through the system
loader, which finds the chain install through ``ld.so.conf`` in the Linux image and through ``PATH``
in the Windows image. The library therefore does not link GenAI, and the packages are unchanged.
Where no GenAI is reachable, ``initialize`` returns ``LibraryUnavailable``; nothing proves that a
GenAI found this way is the chain build, which the image builds verify instead.

``initialize(model_dir, provider)`` reads a GenAI model directory: ``genai_config.json``, the ONNX
files and the tokenizer. ``ExecutionProvider::Cpu`` clears the providers the config names;
``Cuda`` and ``DirectML`` append ``cuda`` or ``dml`` and fail with ``ProviderUnavailable`` where the
library lacks them. The enum is the detector's (``kataglyphis.execution_provider``); ``MigraphX``,
``Xnnpack`` and ``Dnnl``, which GenAI has no route to, return ``ProviderUnavailable`` before any
library is loaded.

Generating
----------

``generate(messages, options, on_text)`` applies the model's own chat template with the generation
prompt, then decodes at most ``max_new_tokens`` tokens. ``temperature`` 0, the default, decodes
greedily and ignores ``top_p`` and ``top_k``. ``on_text`` receives each decoded piece on the
generating thread; a piece that ends inside a UTF-8 character is held back until it is complete,
so a token can produce no piece at all. It must not call back into the same generator, except
``request_cancel``.

The result holds the text, the token ids, the prompt's token count, the time to the first token
and the decode rate after it. ``finish_reason`` is ``Stop`` when the last token is one of the
tokenizer's end tokens, ``Length`` when the budget ran out, and ``Cancelled`` after
``request_cancel``. A cancel ends the run after its current token and applies only to a running
``generate``. One generator serves one call at a time; concurrent callers wait.

Three options shape the reply:

- ``seed`` makes sampling repeatable: the same seed, prompt and options give the same token ids.
  Unset, GenAI draws one; a negative seed is ``InvalidOptions``. Greedy decoding ignores it.
- ``json_schema`` holds the output to a JSON schema through GenAI's llguidance. A GenAI built
  without llguidance, as the Windows chain is (``USE_GUIDANCE=OFF``), refuses with
  ``JsonSchemaUnsupported`` instead of decoding unconstrained text; an invalid schema is
  ``InvalidOptions``. A schema that allows free whitespace can let a small model loop on it until
  the budget ends, so the tests pin ``"x-guidance": {"whitespace_flexible": false}``.
- ``stop`` ends generation before the first of its strings. The text and ``on_text`` never contain
  it: text that could still become a stop string is held back until it cannot, and released when
  generation ends otherwise. ``finish_reason`` is then ``Stop``. An empty stop string is
  ``InvalidOptions``.

Not yet: images or audio as input.

C API
-----

``kataglyphis_c_api.h`` wraps the same calls behind an opaque ``kataglyphis_text_generator``:
``kataglyphis_text_generator_create``, ``_generate``, ``_cancel`` and ``_destroy``, with
``kataglyphis_text_options_default`` and ``kataglyphis_text_status_message``. Text arrives only
through the callback, as a pointer and a length valid during the call, so no string crosses the
boundary with an owner. Status codes are the C++ ``TextGenError`` plus one, so 0 is success;
``Test/compile/api_contract_test.cpp`` pins every pair, and ``c_header_consumer.c`` drives the API
from C17.

``kataglyphis_text_options`` is a sized struct. Its first field, ``struct_size``, holds the size the
caller compiled; ``kataglyphis_text_options_default`` sets it to this header's size and fills every
field with the C++ default. Fields are only ever appended, and ``_generate`` reads a field only when
``struct_size`` reaches its end, so a struct from an older header gets the defaults for what it
lacks. ``KATAGLYPHIS_TEXT_OPTIONS_V1_SIZE`` is the first sized layout, ``struct_size`` through
``top_k``; a smaller ``struct_size`` is ``KATAGLYPHIS_TEXT_INVALID_ARGUMENT``. The appended fields:

- ``seed``: ``KATAGLYPHIS_TEXT_NO_SEED`` (any negative value) lets GenAI draw one; above
  ``INT32_MAX`` is an invalid argument.
- ``json_schema``: ``NULL`` or empty for none. Without llguidance ``_generate`` returns
  ``KATAGLYPHIS_TEXT_JSON_SCHEMA_UNSUPPORTED`` (10), its own status.
- ``stop`` and ``stop_count``: an array of non-empty strings; a count with a ``NULL`` array is an
  invalid argument.
- ``token_ids`` and ``token_id_capacity``: an optional buffer that receives the first generated
  token ids; ``stats.completion_tokens`` counts them all.

This changed the ABI: ``struct_size`` went in front of ``max_new_tokens``, so a caller built
against the previous header must be rebuilt. ``Test/compile`` pins ``sizeof`` and every
``offsetof`` of the three public structs in C++ and again in C17, and ``Test/commit/c_api_test.cpp``
passes a heap block of exactly ``KATAGLYPHIS_TEXT_OPTIONS_V1_SIZE`` bytes, so a read past it fails
under AddressSanitizer.

Python and the CLI
------------------

``kataglyphis_inference.TextGenerator`` takes ``(role, content)`` pairs and an optional callable
for each piece; it releases the GIL while it loads and generates. An exception raised by that
callable cancels the run and is raised again from ``generate``.

.. code-block:: bash

   AccelerANTgine --chat_model <model-dir> --prompt "What is the capital of France?" --max_new_tokens 32

The reply goes to stdout as it is generated, and the token count and speed to stderr.
``--temperature``, ``--seed``, ``--json_schema`` (the schema's text) and ``--stop`` (comma-separated)
set the options of the same names; ``GenerationOptions`` in Python carries ``seed`` (``None`` or an
``int``), ``json_schema`` and ``stop`` (a list of strings).

Tests
-----

No suite loads a model file. CMake writes the hub's tiny GenAI model into the build tree at
configure time (``kataglyphis_use_tiny_genai_model``), and the tests read its ``fixture.json``:
greedy decoding of ``abc`` yields ``defg``, and from the byte ``0xBF`` it runs to the end token.
The build also copies it beside each suite, where a staged suite or one whose build tree moved, such
as the Windows lane's debug run, finds it once the configure-time path is gone.
The commit suite covers the C++ and C calls, the CLI cases cover the chat mode, the compile suite
the C17 header, and ``Test/python/test_text_generation.py`` the binding, including eight threads on
one generator. The tiny model also proves the options: a repeated seed repeats its token ids, four
seeds at temperature 1.0 give at least two sequences of at least 16 tokens, the schema output parses
and holds to its schema (on Windows the schema tests assert ``JsonSchemaUnsupported`` instead), and a
stop string ends with ``Stop``. The Linux skip gate fails a skipped test, so all of these run there.

The real-model contract runs the release ModelANT publishes,
`smollm2_135m_instruct <https://github.com/Kataglyphis/ModelANT/releases/tag/smollm2_135m_instruct-v1>`__,
pinned by ``resources/models/llm.lock``. ``ci-build-and-test.sh`` and ``ci-python-bindings.sh``
fetch it with the hub's ``fetch-data-lock.py --extract`` into ``resources/models/`` and set
``KATAGLYPHIS_REQUIRE_MODEL=1``, so CMake fails instead of leaving the suite out. CMake then adds
``Test/contract/`` to the commit suite, and ``Test/python/contract_text_generation.py`` runs by name.
Each replays ``third_party/ModelANT/contracts/text-generation-v1.json``'s single case,
``capital-of-france``: greedy decoding must give exactly its ``expected_ids``
``[504, 3575, 282, 4649, 314, 7042, 30, 2]``, through C++, C and Python, and the text must contain
``Paris``. A build without the fetched model has no contract tests; nothing skips.
