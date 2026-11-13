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

- [ ] **Different causes share one error code, and the reason stays in the log** (M, ★★). Every code has a
  name since 2026-11-13 (`to_string` beside each enum), but the code still says too little: in
  `VideoDetectorPipeline::initialize` a failed GStreamer init and a pipeline that does
  not parse are both `SessionCreationFailed` (`Src/yolo_detector.cpp`). The reason is in the log only:
  `initialize_gstreamer` frees GLib's message unlogged (`Src/gstreamer_pipeline.cpp`), Python cannot read
  `provider_error()`, and the text generator logs GenAI's message (`Src/text_generation.cpp`) while Python and the
  C API return one fixed text per status.

  First: a last-error text on the engine and the detector, as `provider_error()` keeps it for one case, bound to
  Python, whose exception becomes a `RuntimeError` subclass with `.code`; the C API gets a last-error function,
  appended. Done when a pytest reads the reason of a failed load from the exception.
  A late frame and the end of a stream have their own values since 2026-11-13 (`FrameTimeout`, `EndOfStream`); a
  broken stream and a pipeline without a sink still share `InputAllocationFailed`.
  Ask the owner before producing or reserving the ten values nothing in `Src/` returns (five `WebRTCError`, four
  `GStreamerError`, `OnnxError::MemoryAllocationError`).

- [ ] **A callback that stops its own stream hangs, or ends the process** (M, ★★). Read from the lock order, not
  run. `on_new_sample` calls the buffer callback under `callback_mutex` (`Src/gstreamer_pipeline.cpp:297-298`) and
  `stop()` waits on that mutex (`:421`), so `stop()` from a frame, detection or error callback never returns.
  `WebRTCStreamer` calls its state and error callbacks under its lock on the loop thread
  (`Src/webrtc_streamer.cpp:184-203`) and `stop()` joins that thread (`:604`): a thread that joins itself throws,
  and `-fno-exceptions` makes that the end of the process. Nobody does it today: demo and CLI stop from the main
  thread, and Python binds none of the three classes. Only the text generator states its rule
  (`Src/text_generation.ixx:88`).

  First: one comment line at each `set_*_callback` and a sentence in `docs/source/inference_preprocessing.rst`, which
  says only where callbacks run. Then remember the callback's thread and refuse `stop()` and `create_pipeline()` from
  it with one log line, and add `request_stop()`, an atomic flag that makes `on_new_sample` return `GST_FLOW_EOS`, so
  `has_ended()` reports the end. `WebRTCStreamer` gets its `request_stop()` with its bus rework (the entry on its
  older copies).
  Done when `StopFromInsideACallbackIsRefusedAndRequestStopEndsTheStream` passes per class, on the TSan lane too, and
  the ctest call in `ci-build-and-test.sh` passes `--timeout 300`: only two tests set `TIMEOUT` today
  (`Test/commit/CMakeLists.txt:91`, `:134`), so a hang ends late, at ctest's default limit.

- [ ] **`WebRTCStreamer` keeps older copies of code that `GStreamerPipeline` has since improved** (L, ★★). Each
  file owns its own "GStreamer is initialised" flag and its own `gst_deinit` (`Src/webrtc_streamer.cpp:33-35`,
  `:425-476`; `Src/gstreamer_pipeline.cpp:30-31`, `:319-346`), and the scanner failure is seen only when the
  streamer initialises first (`webrtc_streamer.cpp:431-445`). Its state is a plain exchange, so a late PLAYING
  overwrites Error (`:184-191`); the CLI keeps its own latch for that (`Src/cli_main.cpp:323-324`) and
  `Test/commit/webrtc_streamer_test.cpp:255` tolerates it. It has its own copy of `parse_pipeline_description`
  (`webrtc_streamer.cpp:513-526`). `reconnection_timeout_ms` is parsed and bound and never used
  (`Src/config_loader.cpp:93`), so a restarted signalling server ends the stream. The double init is latent so far:
  no program uses both classes in one process.

  First, each small: make Error final in `set_state` until `stop()` or `configure()` and delete the CLI latch; call
  the shared parse helper; one internal owner for GStreamer init that also holds the scanner flag. Later, once the
  sporadic WebRTC segfault (its own entry) has a stack, because it is the same code: read the bus with a sync handler
  or give the loop its own `GMainContext` (the watch sits on the caller's context, `webrtc_streamer.cpp:533-540`,
  the loop on the global one, `:554-555`), and drop the second bus reader in `stop()` (`:590-599`).
  Done when `ErrorStaysUntilStop` replaces the tolerant check and
  `TheScannerFailureIsSeenWhicheverClassInitialisesFirst`, `DeinitialiseWithALivePipelineIsRefused` and
  `InitialiseAfterDeinitialiseFails` pass; `Cli.StreamStatusTellsAFailureFromAStop` stays the end-to-end proof.
  Ask the owner before touching `reconnection_timeout_ms`: reconnect with a backoff, or write "exit 1 and let the
  service manager restart" in the docs and delete the field.

- [ ] **Stream settings that do nothing, and config mistakes that fall back to defaults** (M, ★★).
  The WebRTC pipeline text never uses `bitrate_kbps`, `turn_servers`, `peer_id` or `producer_id`, and both H.264
  encoder choices give the same text (`Src/webrtc_streamer.cpp:252-290`); `set_bitrate` only stores its number
  (`:657-662`) behind the CLI's `--bitrate`. `initialize` accepts a host that has `webrtcbin` alone, while every
  pipeline names `webrtcsink` (`:447-462`). A `--config` file that fails to load is a warning and the stream starts
  on defaults (`Src/cli_main.cpp:299-308`), and an unknown source or encoder name falls back with a warning
  (`:184-201`); a TOML value of the wrong type keeps the default without a word (`Src/toml_config.cpp:27-48`). The
  default STUN server is written `stun:host:port` (`Src/config_loader.cpp:78`) and the fallback `stun://`
  (`webrtc_streamer.cpp:286`); nobody ran the first form.
  Never read: `DetectionResult::class_confidences`, `VideoDetectionConfig::output_path`,
  `PipelineConfig::timeout_ms`, and the leftover members at `Src/gstreamer_pipeline.cpp:192-205` and `:305-308`.

  First: export `webrtc_pipeline_description(const StreamConfig&)` like the other builders, then wire or delete each
  `StreamConfig` field; a named `--config` that does not load exits 2 with the reason.
  Done when a table test `EveryStreamSettingChangesThePipelineText` holds every field, with a structured binding of
  the exact field count beside it, and a ctest `Cli.ABrokenConfigFileFails` passes.
  Ask the owner before: (1) changing a fall-back that a named test pins
  (`TomlConfig.WrongTypesFallBackToTheDefaults`, `OutOfRangeIntegersFallBackToTheDefaults`,
  `WebRtcStreamConfig.UnknownNamesFallBackToTheArguments`). Proposed: TOML reports a wrong type and keeps ignoring
  unknown keys, as the JSON loader does, and the tests flip in the same commit. (2) Deleting the six tensor builders
  (`Src/gstreamer_pipeline.cpp:375-398`, `:501-613`), which only tests call: hub CON185 and CON198 are still open
  on whether the image gets their elements. On the day the elements arrive
  `GStreamerPipeline.TheInferencePipelineNeedsNnstreamer` would skip, and so fail the Linux no-skip rule.

- [ ] **The Python surface lags the C++ structs, and nothing fails when a field is added** (M, ★★).
  `YoloConfig` has 13 fields (`Src/yolo_detector.ixx:76-93`) and the bindings expose nine
  (`Bindings/python/kataglyphis_bindings.cpp:326-336`): `preprocess_mode`, both thread counts and `labels` are
  missing. `YoloDetector` binds `detect` on ready float tensors only (`:338-372`), so every Python caller writes by
  hand the resize and normalise step that the ModelANT contract pins
  (`docs/source/inference_preprocessing.rst:10-14`).
  The engine lacks `provider_error`, `end_profiling`, `get_custom_metadata` and `applied_intra_op_num_threads`
  (`kataglyphis_bindings.cpp:210-284`), and `SessionConfig` lacks `profiling_prefix` (`:190-199`).

  First: bind the frame path, `detect_frame` and `preprocess_frame` on a C-contiguous uint8 HWC array plus its
  format; only then does `preprocess_mode` do anything and can be bound. Then the thread counts, `labels` (with
  `nb::lock_self()`), the detector's `output_layout()` and the error text; copy the built stub over the tracked one.
  Done when each bound struct has a structured binding with its exact field count in the bindings, so a new field
  stops the build until someone decides, and a pytest compares the attribute names of `YoloConfig()` and
  `SessionConfig()` with a list. Fields left out on purpose are named beside the guard.

- [ ] **The shape getters may crash on a non-tensor and report a dynamic dimension as `SIZE_MAX`** (S, ★★; not
  double-checked). Read from the source, not run. `get_named_shape` (`Src/onnx_inference_engine.cpp:278-288`, used
  at `:596-614`) calls the C++ wrapper chain `GetTensorTypeAndShapeInfo().GetShape()`, although line 39 says a
  fallible call goes through the C API because the wrapper aborts under `ORT_NO_EXCEPTIONS`. For a sequence or map
  the wrapper should hand back a null info that `GetShape()` reads through; that part is from memory of the ORT
  wrapper, whose headers were not at hand. `to_tensor_shape` (`:76-82`) casts `int64` to `size_t`, so a dynamic -1
  becomes 18446744073709551615. Both getters are bound to Python
  (`Bindings/python/kataglyphis_bindings.cpp:269-284`), and the shape tests ask tensor models only
  (`OnnxEngine.ReportsInputAndOutputNamesAndShapes`, `AnUnknownNameHasNoShape`). Since a3bc65d
  `YoloDetector::initialize` asks both getters for every model, and its `fixed` helper reads the wrapped -1 as
  dynamic.

  First: rewrite `get_named_shape` with the C API, as `to_tensor_data` does (`onnx_inference_engine.cpp:84-124`), so
  a non-tensor is `InvalidInputType` or `InvalidOutputType`. Ask the owner how a dynamic dimension is reported (0,
  or an optional): it is public API, and `fixed` in `Src/yolo_detector.cpp` follows the answer.
  Done when `TheShapeOfASequenceOutputIsInvalidOutputType` (the existing `sequence_output_model()`) and
  `ADynamicDimensionIsReportedAsDynamic` pass under ASan and UBSan, with one pytest for the bound getters.

- [ ] **"Newest frame, no backlog" is tested as text only, and the pipeline counts nothing** (M, ★★; not
  double-checked). `YoloDetector.TheCameraPipelineKeepsOneFrameBetweenCaptureAndTheDetector` checks substrings of
  the camera description that 6219631 wrote; `v4l2src` is part of the same string
  (`camera_detection_pipeline_description`), so CI cannot run the leaky tail without a camera.
  `VideoDetectorPipeline::Impl` keeps no frame count, lag or inference time, so "does the detector keep up?" cannot
  be asked, tested or benchmarked.

  First: split the camera description into a source head and an exported live tail that a test puts behind
  `videotestsrc is-live=true`. Add a few atomics behind a `stats()` accessor: frames processed, first and last frame
  time, last inference ms, error count. Dropped frames follow from the frame times and rate `FrameMetadata` carries.
  Done when `ASlowDetectorSeesTheNewestFrame` passes, on the TSan lane too: a live 30 fps source and a detection
  callback that sleeps 200 ms for five frames give gaps of several frame periods and `stats().dropped` above zero,
  and the file tail gives zero. The counters then feed a warn-only pipeline benchmark in `bench-history`.

- [ ] **The instruction-count gate cannot tighten and guards x64 only** (M, ★★). `check()` fails only on "over"
  (`scripts/linux/perf-cachegrind.py:88-100`), so after a speed-up the old ceiling stays and the gain can be lost
  again without a failure. Not measured: whether 6219631 moved `BM_PreprocessFrame`;
  `perf/cachegrind-baseline.json` is unchanged since 3441996. It holds `x64-clang` and `x64-gcc` only, and `perf/`
  has one host baseline, a Ryzen 9 5950X, so nothing is graded on the Pi's CPU. The gate has a unit test
  (`.github/workflows/lint-gates.yml:76`) and no recipe in `scripts/linux/tests/lane-mutations.json`.

  First: a lower bound in `check()`: a count under the baseline by more than the allowance fails with "re-record the
  baseline". One run may lower an entry, since the recorded spread is under 1e-5; widening keeps its five runs. Add
  the case to `test-perf-cachegrind.py` and one mutation recipe per bound.
  Then: arm64 entries from five `[ci arm64]` runs with `--summarize`; a gated benchmark of `run_inference_in_place`
  at 3x640x640, the path the detector takes since 6219631 (`BM_OnnxRunInference` times the copying one,
  `Test/perf/perfSuite.cpp:157`); `BM_TextGenerateTiny` under the same counter if its spread stays under 1 %, which
  nobody has tried; `perf/baseline-<cpu>.json` for the Pi from `quality-report.sh --perf-host --update-baseline`, as
  a `systemd-run` unit when the board is quiet.
  Done when both x64 keys fail in either direction and the arm64 keys fail when missing.
  Ask the owner before letting one run lower an entry: `AGENTS.md` (section 5, the perf gate) re-records from five or more runs, and a
  lower bound adds a re-record step after every intended speed-up.

- [ ] **The ORT thread default is a fixed 4 and 4, measured on no target** (S, ★★). `YoloConfig` and
  `SessionConfig` default to 4 intra-op and 4 inter-op threads whatever the machine (`Src/yolo_detector.ixx:89-90`,
  `Src/onnx_inference_engine.ixx:66-67`). The recorded baselines of one Ryzen host pinned to 8 CPUs, same photo and
  model: C++ 30.27 ms, Python 24.13 ms with its default (usable CPUs minus one, at most 8) and 51.26 ms with ORT's.
  That the thread count explains the gap is inferred, not run; nothing is measured on the Pi, where four ORT threads
  meet four cores.

  First: measure, change nothing: the demo's `--detector-latency-runs 30` with `--threads` 2, 3, 4 and 7, pinned and
  unpinned, and on the Pi when it is quiet.
  Done when `quality-report.toml`'s `[perf]` times the shipped default against ORT's default in one run with a ratio
  check, as OrchestrANT's does.
  Ask the owner, with the numbers, before replacing the literal 4: the family policy from Python, or another value
  for a 4-core board; the inter-op 4 needs its own answer.

- [ ] **Every chat turn runs the whole conversation through the model again** (M, ★★; not double-checked, not
  measured). `TextGenerator::generate` templates and encodes all messages and builds a new generator on every call
  (`Src/text_generation.cpp:519-523`), so the time to the first token should grow with the length of the chat.

  First: measure. Replay a fixed five-turn chat on SmolLM2-135M and compare the time to first token of turn 1 and
  turn 5, as a `--perf-host` row. Only if it matters: keep the last generator and its token ids with the model, and
  append only the new tokens when the old ids are a prefix of the new prompt; check the pinned `ort_genai_c.h` for
  appending to a live generator before planning.
  Done when that row is in the baseline and a tiny-model test shows that turn 2, extending turn 1, gives the ids of
  a fresh run.

- [ ] **`preprocess_frame` and the pipeline quoting are not fuzzed** (S, ★★). The nine fuzz targets cover the
  decoder and the two parsers (`Test/fuzz/yolo_decoder_fuzz.cpp`, `Test/fuzz/config_fuzz.cpp`). `preprocess_frame`
  does the size, stride and offset arithmetic before it reads raw bytes, 6219631 rewrote it for speed, and its
  tests (the three `FramePreprocessing` cases) use frames of at most 3x2 pixels. `quote_pipeline_value`
  (`Src/gstreamer_pipeline.cpp:488-499`), all that stands between a file name and a gst-launch string, has one
  example test.

  First: `FUZZ_TEST(PreprocessFuzz, NeverReadsOutsideTheBuffer)` over format, size, stride, offset, a declared size
  apart from the real one, target size and both modes; the answer is an error or exactly 3*w*h values within 0 to 1.
  Beside it a naive `nearest_floor` reference compared value by value, which protects every later speed-up. For the
  quoting a pure property: an unescape rule written in the test gives the value back, and the quoted text holds no
  unescaped quote.
  Done when both run in the clang Debug lane's `fuzzTestSuite` (ASan, fatal UBSan), and the test's comment records
  one run by hand with a bound check removed that the target caught.
  Later: a dispatch-only tree with fuzzing mode on and a kept corpus; `third_party/CMakeLists.txt:83-93` forces it
  off because it clashed with ASan.

- [ ] **No mutation recipe touches the detector code** (M, ★★; not double-checked). All 60 recipes in
  `scripts/linux/tests/lane-mutations.json` change scripts, CMake or packaging files, none a file under `Src/`;
  OrchestrANT has 13 `yolo.*` and 7 `cv.*` recipes for the same decoding and preprocessing rules. So no recipe has
  shown that the contract and golden tests here can fail.

  First: a handful of recipes against `Src/yolo_detector.cpp` in OrchestrANT's style: swap red and blue, round the
  letterbox down, drop the pad offset, ignore the score threshold. Each must fail the `FramePreprocessing` and
  `YoloDetector` tests or the `golden` label. One more holds the owner decision of 2026-11-12 (DEIM rows get no
  overlap suppression in any of the three detectors, raw YOLO heads keep theirs; here since a3bc65d): suppression
  put back on `xyxy_score_class` rows must fail.
  Done when a workflow runs them and fails on a recipe no test catches. They need a build in the image, unlike the
  fixture recipes `mutations.yml` runs today: owner decision 2026-11-13: a weekly run of its own, not a job on
  the Linux x64 lane.
  Built by hand on 2026-11-13 (clang Debug, arm64), each caught: the cut to the frame removed, suppression put back
  on corner rows and the corner-order check dropped all fail
  `YoloDecoder.MatchesTheDecodeCasesOfTheSharedModelAntContract`; the cut moved before suppression fails
  `YoloDecoder.RawHeadBoxesAreCutToTheFrameAfterSuppression`; the frame no longer required fails
  `YoloDecoder.AMappingWithoutAFrameIsInvalidInputShape`. These five are the first recipes for that workflow.
  The review built nine more the same way, each caught. The class range unchecked or one too wide, the score's or
  the corners' finiteness unchecked and a strict threshold fail the replay; the last three fail no other test. The
  frame's sides swapped in `preprocess_frame`, and `detect` naming the input as the frame, fail the
  `FramePreprocessing` and `YoloDetector` tests. The contract without `decode`, or with no decode case, fails the
  replay.

- [ ] **No shared case holds the two schema errors** (S, ★). C++ and Rust agree since 2026-11-13 (owner decision):
  a schema that is no JSON object is `InvalidOptions` before the engine, and an object the generator refuses is
  `GenerationFailed`. Each side tests it with its own schemas. A case in the hub's tiny-model `fixture.json` would
  hold both (hub). When that fixture grows a `cases` list, `Test/commit/text_generation_test.cpp` and `Test/python`
  read it instead of retyping; here only the 0xBF rule is retyped.
  `Test/contract/text_contract_test.cpp` expects exactly one contract case on purpose, so plan it with the pin
  bump that adds one.

- [ ] **Nothing runs the suite twice in one tree, and one script suite runs nowhere** (S, ★). c29f25a removed the
  known cause of a failing second `ctest` in one build directory: `--detector-image` decodes the image before it
  creates its outputs. No guard holds that: CI runs ctest once per fresh checkout
  (`scripts/linux/ci-build-and-test.sh:69-81`), so the next test that leaves a file behind fails only on a dev box.
  `scripts/linux/tests/test-demo-detector-safety.sh`, the test of "outputs must be new", is named by no workflow,
  script or CMake file.
  First: register the safety suite as a ctest with the built demo, the locked model and `two_cats.jpg`; it takes
  `DEMO MODEL FIXTURE.jpg`, so it cannot join a list of suites without arguments.
  Done when the Linux lane runs ctest a second time on the same tree and passes (about 13 s on the Pi, from the
  owner's notes, not a repo figure).

- [ ] **GenAI gets no chain proof at configure time; ORT has one** (S, ★).
  `cmake/SystemLibDependencies.cmake:106` asserts the chain marker in the ORT library and only searches GenAI's
  header (`:163-196`); `Src/text_generation.cpp:80-105` loads the library by bare name. That load is a written
  decision (`docs/source/text_generation.rst:15-19`) and the hub's G6 census proves shipped trees, so this is a known
  limit, not an oversight.
  First: call `accelerantgine_assert_ort_chain_build` for the GenAI library under the prefix its header was found
  in, with GenAI's marker; nothing changes at run time. Done when its recipe in
  `scripts/linux/tests/lane-mutations.json` fails without the call.

- [ ] **`kGenaiHasGuidance` is a switch with one position** (S, ★). Since 2fb3ab7 every lane's GenAI has llguidance
  and the constant is `true` everywhere (`Test/common/kataglyphis_test_support.h:259`, read at
  `Test/commit/text_generation_test.cpp:203` and `Test/commit/c_api_test.cpp:240`). Delete it with its dead
  branches; the mapping of "Guidance is unavailable" to `JsonSchemaUnsupported` (`Src/text_generation.cpp:158-162`)
  stays. Done when `rg kGenaiHasGuidance` finds nothing outside `CHANGELOG.md`.

- [ ] **Each frame is written twice in two places** (S, ★; the saving is not measured).
  `extract_buffer_info` resizes the vector, which zero-fills it, then copies the frame over it
  (`Src/gstreamer_pipeline.cpp:165-168`; 2,764,800 bytes at 1280x720 RGB). `preprocess_frame` fills the whole
  3x640x640 float tensor and in stretch mode overwrites every value, and builds `column_offsets` anew per frame. By
  instruction count our code is about 1 % of a detected frame (11.8 of 1,199.5 million,
  `perf/cachegrind-baseline.json`), and the gate runs with `--cache-sim=no`: only wall time on the Pi can show a
  gain.
  First, as small changes on the way: `data.assign(ptr, ptr + size)`, and one `Ort::MemoryInfo` made in
  `initialize`. Then a scratch tensor in `VideoDetectorPipeline::Impl` through a `detect_frame` overload, not
  `thread_local` (the TLS trap of the module targets, `AGENTS.md` § 4). A live RTSP camera is a `://` source and is
  treated as lossless like a file (`video_detection_pipeline_description`, on purpose in 6219631); it wants an
  explicit switch.
  Done when the contract test still gives identical floats and a Pi wall-time figure, before and after, is recorded
  here.

- [ ] **clang-tidy's size and complexity limits are the tool's defaults** (S, ★). `.clang-tidy` turns on
  `readability-*` (line 27) and sets no threshold for `readability-function-size` or
  `readability-function-cognitive-complexity`, so the graded clang-tidy set can move with the clang version. A new
  complex function already shows in that set; the limit it is held to is written nowhere. The hub's reader,
  report-only for C++, counts 10 of 352 functions over its size limit (`OnnxInferenceEngine::initialize` 316 lines,
  `prompt_tokens` 144, `best_class` 125).
  First: write the line and cognitive thresholds into `.clang-tidy`; the first run names today's offenders.
  Done when both thresholds are in `.clang-tidy` and the new members of the clang-tidy set are fixed or recorded.

- [ ] **`yolo_detector.cpp` does three jobs, and `Src/` is a recursive glob** (M, ★). One file of about 800 lines
  holds the pure math (preprocess, decode, suppression), the ORT-backed detector and the video pipeline with its
  factories. `Src/CMakeLists.txt:5-19` globs `*.cpp` and `*.ixx` without `CONFIGURE_DEPENDS`; stray cargo files
  under `rusty_code/target` needed a filter (6219631).
  Cheap parts only: three implementation units of the same module, with no flag change, and an explicit source
  list. A separate static target for the math waits until coverage-guided fuzzing is wanted: its flags must match on
  every compiler, the riscv64 cross build and the Flutter plugin.
  Done when a source file missing from the list fails the link.

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
