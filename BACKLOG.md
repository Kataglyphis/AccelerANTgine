# Backlog

Entries use the agentic loop's checkbox markers, `- [ ]`, `- [b]` and `- [x]`
([`windows-agentic-loop.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/windows-agentic-loop.md#prerequisites)
says what each means). Effort S/M/L, impact ★ … ★★★.

## Open

- [ ] **LAI-A4: a GStreamer audio appsink and Whisper captions** (L, ★★). Captions as `textoverlay`
  and WebRTC data, from the hub's language-AI milestone 3 (`docs/language-ai.md`).

- [ ] **A package with `GST_REGISTRY_FORK=no` and no scanner gives webrtcsink an empty codec list on a fresh
  registry** (M, ★★). `Src/bundled_gstreamer.cpp` sets it. Reproduced 2026-11-03 in `:latest` with the Linux
  package's plugin list on a tmpfs that lists `libgstrswebrtc.so` first: in process the stream fails with
  `No codec available`; the image's scanner on the same order streams. So the in-process path cannot be proved; the
  scanner has to ship. Left: install `gst-plugin-scanner` in the Linux tarball, DEB and AppImage under the bundled loader
  (OmniAccelerANT's `package-observant.sh` has the wrapper) and in the Windows ZIP, MSI and MSIX; name it in
  `GST_PLUGIN_SCANNER` and drop the fork there; add it to `packaging/third-party/components.json`, since the notice gate
  classifies every ELF and PE. Done when the finished packages stream on that forced order.

- [b] **DNNL cannot run in `:latest`** (S, ★★; blocked on the hub image, CON191). The chain ORT
  lists `DnnlExecutionProvider` on amd64, but `libonnxruntime_providers_dnnl.so` needs
  `libdnnl.so.3`, which the image does not ship (its RUNPATH names the build directory), so
  `ExecutionProvider::Dnnl` is `ProviderUnavailable` there; arm64 does not build it. Second
  trap: a process that resolves `libonnxruntime.so.1` through `/opt/opencv5/lib` makes ORT look
  for every provider library in that directory. `Golden.DnnlMatchesCpuOrIsProviderUnavailable`
  and `OnnxEngine.DnnlRunsOnlyWhenItsLibraryLoads` switch to the CPU-parity branch on their own
  once `libdnnl.so.3` loads.

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
  Attempts: 2026-11-03, 120 runs without a crash (x64; 60 Debug ASan, 60 `linux-profile-GNU`; 8 s each, no viewer).

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

- [ ] **The NVIDIA packages have not run on a GPU they support** (S, ★★★). The Linux and Windows packages are built and
  passed on the CPU, and hosted runners have no GPU. Done on an RTX 30xx or newer when
  `compare_detector_parity.py` passes against the CPU and the profile shows the provider; the hub's
  `docs/gpu-artifact-receipts.md` has the commands. DirectML on an NVIDIA card is unproven too.
  The owner runs this on a machine with an NVIDIA GPU. No release until this and the Linux AMD check are done.

- [ ] **The Linux AMD packages have not run on a GPU** (S, ★★★). They are built and passed on the CPU, and hosted runners
  have no GPU. Under WSL on the RX 9070 XT even a plain HIP copy does not return (hub CON202), so this takes native
  Linux: the owner runs it under Ubuntu on that machine. Done when `compare_detector_parity.py` passes against the
  CPU and the profile shows MIGraphX; the hub's `docs/gpu-artifact-receipts.md` has the commands.

## Recorded probes

- **llguidance accepts the hub tiny model's tokenizer** (S, ★★). Probe of 2026-11-01 in
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

## Quality queue

The top 5 of `logs/code-quality/queue.md` (`bash scripts/linux/quality-report.sh`); re-sync when it moves.

- [ ] `doc-dupes-hub.allow:4` budget 23 (allow_budget_total)
- [ ] `shellcheck-warnings.allow:20` budget 7 (allow_budget_total)
- [ ] `shellcheck-warnings.allow:16` budget 5 (allow_budget_total)
- [ ] `shellcheck-warnings.allow:15` budget 3 (allow_budget_total)
- [ ] `shellcheck-warnings.allow:14` budget 2 (allow_budget_total)
