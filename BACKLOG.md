# Backlog

Entries use the agentic loop's checkbox markers, `- [ ]`, `- [b]` and `- [x]`
([`windows-agentic-loop.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/windows-agentic-loop.md#prerequisites)
says what each means). Effort S/M/L, impact ★ … ★★★.

## Open

- [ ] **A sporadic segfault in the CLI's WebRTC workload** (M, ★★). On 2026-10-15 the Linux
  arm64 gcc job (release, LTO) of a82d9bf, run 38672470256 attempt 1, died in
  `scripts/linux/ci-profile-bench.sh`: `bin/AccelerANTgine` streaming `videotestsrc ! … !
  webrtcsink` to the local signalling server ended in SIGSEGV (exit 139); attempt 2 of the
  same commit passed, and the commit only moved `inference_demo.cpp` out of the library. The
  WebRTC streamer's success path has no test (`Test/commit/webrtc_streamer_test.cpp` covers its
  errors), so nothing else would catch a race there.

  Crash capture is already wired: `scripts/linux/ci-profile-bench.sh`'s `capture_crash`
  records the status, core and rerun backtrace; `reusable-linux.yml` uploads the evidence on failure.
  Remaining: analyze a stack from a real workload crash and exercise the successful
  start/stream/stop path under Debug ASan; the existing unit tests cover failure paths.

- [ ] **The Python bindings build and test on Linux x64 and arm64 only** (M, ★★). Owner goal
  2026-10-01: every test on every arch, on the pinned CPython once with the GIL and once
  free-threaded. `ci-python-bindings.sh` builds both wheels, installs each and runs
  `Test/python`, but only `ci-run-all.sh:92-97` calls it, on the clang rows of `linux-x64.yml`
  and `linux-arm64.yml`. Missing:
  1. Windows x64 and arm64: no workflow calls `Build-PythonBindings.ps1` (or
     `Invoke-ContainerPythonBindings.ps1`); it builds the GIL package only and runs no test.
  2. riscv64: `ci-riscv64-test.sh` cross-builds and runs the C++ suites alone; no wheel is
     built or imported under QEMU.

  Done when every lane builds both wheels from the image's interpreters and passes
  `Test/python` on each, Windows arm64 on the `windows-11-arm` device.

## Done

- [x] **llguidance accepts the hub tiny model's tokenizer** (S, ★★). Probe of 2026-11-01 in
  `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest` (index `7d4d4129`, GenAI 0.17.0 built
  `--use_guidance`): `OgaGeneratorParamsSetGuidance("json_schema", …)` on the model
  `tiny-genai-model.py` writes is accepted, so the schema tests run on that model and SmolLM2-135M
  is not needed as a fallback. A loose schema lets greedy decoding loop on whitespace inside `{`;
  the tight schema
  `{"type":"object","properties":{"a":{"type":"string","maxLength":3}},"required":["a"],"additionalProperties":false,"x-guidance":{"whitespace_flexible":false}}`
  decodes the prompt `abc` to `{"a":"#$%"}`, then the end token 256. SmolLM2-135M accepts the same
  schema (`{"a":"par"}`). At temperature 1.0 with `top_k` 0 the tiny model gives seed 1 a sequence
  that leaves the successor chain within 24 tokens and seeds 2 to 4 the chain itself, so four
  seeds give two distinct sequences. The Windows chain builds GenAI with `USE_GUIDANCE=OFF`, so
  there a schema fails with `JsonSchemaUnsupported` (LAI-H2 in the hub).
