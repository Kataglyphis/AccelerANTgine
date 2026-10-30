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
library lacks them.

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

Not yet: a JSON schema for constrained output, and images or audio as input.

C API
-----

``kataglyphis_c_api.h`` wraps the same calls behind an opaque ``kataglyphis_text_generator``:
``kataglyphis_text_generator_create``, ``_generate``, ``_cancel`` and ``_destroy``, with
``kataglyphis_text_options_default`` and ``kataglyphis_text_status_message``. Text arrives only
through the callback, as a pointer and a length valid during the call, so no string crosses the
boundary with an owner. Status codes are the C++ ``TextGenError`` plus one, so 0 is success;
``Test/compile/api_contract_test.cpp`` pins every pair, and ``c_header_consumer.c`` drives the API
from C17.

Python and the CLI
------------------

``kataglyphis_inference.TextGenerator`` takes ``(role, content)`` pairs and an optional callable
for each piece; it releases the GIL while it loads and generates. An exception raised by that
callable cancels the run and is raised again from ``generate``.

.. code-block:: bash

   AccelerANTgine --chat_model <model-dir> --prompt "What is the capital of France?" --max_new_tokens 32

The reply goes to stdout as it is generated, and the token count and speed to stderr.

Tests
-----

No suite loads a model file. CMake writes the hub's tiny GenAI model into the build tree at
configure time (``kataglyphis_use_tiny_genai_model``), and the tests read its ``fixture.json``:
greedy decoding of ``abc`` yields ``defg``, and from the byte ``0xBF`` it runs to the end token.
The commit suite covers the C++ and C calls, the CLI cases cover the chat mode, the compile suite
the C17 header, and ``Test/python/test_text_generation.py`` the binding, including eight threads on
one generator. The model release ModelANT publishes for real use is
`smollm2_135m_instruct <https://github.com/Kataglyphis/ModelANT/releases/tag/smollm2_135m_instruct-v1>`__.
