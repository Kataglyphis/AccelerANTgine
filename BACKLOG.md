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
  WebRTC streamer's success path has no test (`Test/commit/webrtc_streamer.cpp` covers its
  errors), so nothing else would catch a race there. Next: keep a core dump as an artifact
  when the workload crashes, or run the same workload under ASan in the Debug lane.

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
