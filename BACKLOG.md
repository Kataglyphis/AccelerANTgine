# Backlog

Entries use the agentic loop's checkbox markers, `- [ ]`, `- [b]` and `- [x]`
([`windows-agentic-loop.md`](https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/windows-agentic-loop.md#prerequisites)
says what each means). Effort S/M/L, impact ★ … ★★★.

## Open

- [ ] **LAI-A4: a GStreamer audio appsink and Whisper captions** (L, ★★). Captions as `textoverlay`
  and WebRTC data, from the hub's language-AI milestone 3 (`docs/language-ai.md`).

- [ ] **No finished Windows GPU package has streamed on a fresh registry** (S, ★★). Linux is done: every tarball, DEB and
  AppImage streams with `libgstrswebrtc.so` listed first (`check-package-fresh-registry.sh`). The Windows GPU ZIP, MSI and
  MSIX carry `gst-plugin-scanner.exe`: `windows-gpu-candidates.yml` run 41738334240 built them and `Test-WindowsGpuPackages.ps1`
  checked the bytes. Left: one of those packages must stream on that forced order; `scripts/windows` has no such check yet.

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
  same commit passed, and the commit only moved `inference_demo.cpp` out of the library.
  `Cli.StreamStatusTellsAFailureFromAStop` now runs a healthy stream against a real signalling server under Debug ASan,
  on x64 clang for 5 s with no viewer; that is not the job that crashed.

  Crash capture is already wired: `scripts/linux/ci-profile-bench.sh`'s `capture_crash`
  records the status, core and rerun backtrace; `reusable-linux.yml` uploads the evidence on failure.
  Remaining: analyze a stack from a real workload crash.
  Attempts: 2026-11-03, 120 runs without a crash (x64; 60 Debug ASan, 60 `linux-profile-GNU`; 8 s each, no viewer).

- [ ] **The Python bindings build and test on Linux x64 and arm64 only** (M, ★★). Owner goal
  2026-10-01: every test on every arch, on the pinned CPython once with the GIL and once
  free-threaded. `ci-python-bindings.sh` builds both wheels, installs each and runs
  `Test/python`, but only `ci-run-all.sh` calls it, on the clang rows of `linux-x64.yml`
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

- [ ] **AMD's plugin MIGraphX provider has not run from this library, on a card or in the rocm image** (M, ★★★; hub
  CON231 step 2). `ExecutionProvider::MigraphX` registers `libmigraphx-ep.so` since 2026-11-12. Proven here, on arm64
  without a card: the module search, the guard, the option set and the three error paths against the real ONNX Runtime
  1.31.1, with a missing module, a file that is no ELF and the stand-in `Test/common/plugin_ep_stub.cpp`, also from
  eight threads at once and after another library registered the name; the script suites with fixtures in the new
  layout. Not proven: every line that needs AMD's module. The 2026-11-07 parity pass was the in-tree provider's.
  Under WSL on the RX 9070 XT even a plain HIP copy does not return (hub CON202), so the card run takes native
  Linux: the owner runs it under Ubuntu on that machine.

  Done when `linux-gpu-candidate.yml` builds the amd-x64 packages in `:latest-rocm`, their clean-host job passes
  (`--device migraphx` must fail there on the packaged module), and on the card `profile-gpu-candidate.sh <dir>
  models/deim_dfine_n_coco.onnx migraphx` passes: `compare_detector_parity.py` against the CPU, and the plugin's
  operators in the profile under the provider name `MIGraphX`. Then run the commit suite once with
  `-DKATAGLYPHIS_TEST_MIGRAPHX=ON`.

  The first run (43409259960, a2345f4, hub pin ed3d170) built the amd-x64 tarball and DEB in `:latest-rocm` with
  their licence proofs, and stopped where item 1 expected. What stops it, in order:
  1. Seen: `verify-ort-appimage-payload.sh … amd` in CPack's AppImage check fails with `expected one wheel matching
     every native library; found 0`. It asks for the wheel's exact bytes where the image strips the CPU core: hub
     BACKLOG CON256 (i), whose fix needs an x86-64 host. Until then the amd leg is red on every `[ci gpu-lin]` and
     `[ci all]` run, and its clean-host job with it. This repo calls no census on its Linux packages; if it adds
     one, the hub's `--library-path` (pin ed3d170 holds it) names the launcher's directory.
  2. The profile's provider name: the hub's `verify_ort_profile.py` expects `MIGraphX`, and
     `test-diagnose-migraphx-detector.sh` reads the name from the pinned hub's table, so only a card shows a mismatch.
  3. Never run anywhere: the hub's `stage_ort_runtime … amd` in `CPackOptions.cmake`, the ELF closure with the module
     protected, the install-time proof against the image's module, and the plugin's licence tree, which nobody here
     has seen (the inventory takes whatever `licenses/` holds).
  4. Read, not run: AMD's module takes the registration name as its provider name, takes the card from `device_id`,
     refuses a second device and any option it does not list, and its registration calls HIP.

  Remove with the hub's fix: `accelerantgine_keep_module_in_appimage` (`cmake/OrtPackageVariant.cmake`) keeps CPack's
  AppImage step from patching the module, because the hub's `patchelf-keep-glibc.sh --keep-ort` keeps
  `libonnxruntime*` only; `verify_plugin_texts` (`verify-gpu-packages.sh`) and the inventory's `tree` text stand in
  for a hub helper that stages the plugin's `licenses/` and `provenance.txt`.

- [b] **CUDA still loads through the in-tree provider** (M, ★★; blocked on the hub's new NVIDIA image, CON233). Owner
  decision 2026-11-12: only AMD moves now. The hub's contract (`docs/consumer-image-contract.md` § *The CUDA plugin
  EP*) says the new `:latest-nvidia` builds `libonnxruntime_providers_cuda.so` as a plugin without `GetProvider`, so
  `SessionOptionsAppendExecutionProvider_CUDA` stops working there: a C++ consumer registers that file once per
  process as `CUDAExecutionProvider`. Here that is one more row in `Src/ort_plugin.hpp` (the name, a root variable,
  the module file; the module already sits beside `libonnxruntime.so.1` in the GPU prefix and in a package), and the
  CUDA branch and `run_one_cuda_kernel` in `Src/onnx_inference_engine.cpp` then go through `append_plugin`.
  `CPackOptions.cmake` and `verify-gpu-packages.sh` keep the wheel proof, since that module is the GPU wheel's.
  Done when the NVIDIA packages' card run (two entries up) passes on that image. Until it is published, a build may
  meet either form of the module.

- [ ] **`WebRTCStreamer` reads its bus on the caller's main context** (M, ★★). The first half is done
  (2026-11-17): GStreamer has one owner, `kataglyphis.gstreamer_runtime`, that both classes initialise, parse and
  deinitialise through, so the scanner failure is seen whichever initialises first, a deinit with a live pipeline
  is refused and an init after a deinit fails instead of crashing; and `Error` stays until `stop()` or
  `configure()`, so the CLI's latch is gone. Left, once the sporadic WebRTC segfault (its own entry) has a stack,
  because it is the same code: read the bus with a sync handler or give the loop its own `GMainContext` (the watch
  sits on the caller's context, the loop on the global one), and drop the second bus reader in `stop()`.

- [b] **The six tensor builders wait for the hub's nnstreamer decision** (S, ★). `Src/gstreamer_pipeline.cpp`'s
  tensor pipeline builders are called by tests only; hub CON185 and CON198 decide whether the image gets their
  elements, and the owner chose on 2026-11-15 to keep them until then. On the day the elements arrive
  `GStreamerPipeline.TheInferencePipelineNeedsNnstreamer` would skip, and so fail the Linux no-skip rule. The other
  unread fields (`class_confidences`, `output_path`, `PipelineConfig::timeout_ms`) are deleted.

- [ ] **The detector's math has no target of its own** (S, ★). Since 2026-11-16 `Src/yolo_math.cpp` holds it as a unit
  of `kataglyphis.yolo_detector`. A separate static target waits until coverage-guided fuzzing is wanted: its flags
  must match on every compiler, the riscv64 cross build and the Flutter plugin.

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
  there a schema fails with `JsonSchemaUnsupported` (LAI-H2 in the hub). Out of date since
  2026-11-12: the Windows chain builds GenAI with llguidance now, and the schema tests expect an
  answer there (2fb3ab7).

## Quality queue

The top 5 of `logs/code-quality/queue.md` (`bash scripts/linux/quality-report.sh`), leaving out `doc-dupes-hub.allow`, which the owner keeps in every AGENTS.md; re-sync when it moves.

- [ ] `shellcheck-warnings.allow:10` budget 2 (allow_budget_total)
- [ ] `scripts/windows/tests/MediaRuntimeReuse.Tests.ps1:43` 39 shared shingles with scripts/windows/tests/MediaRuntimeReuse.Tests.ps1:71 (duplicated_blocks)
- [ ] `Test/commit/cli_stream_status_test.sh:37` 34 shared shingles with scripts/linux/check-package-fresh-registry.sh:40 (duplicated_blocks)
- [ ] `Test/commit/cli_stream_status_test.sh:37` 30 shared shingles with scripts/linux/ci-profile-bench.sh:96 (duplicated_blocks)
- [ ] `scripts/windows/Build-Windows.ps1:508` 24 shared shingles with scripts/windows/Build-Windows.ps1:689 (duplicated_blocks)
