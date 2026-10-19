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
