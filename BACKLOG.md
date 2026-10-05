# Backlog

Follows the protocol ANTfrastructure's agentic loop (`shared/agentic-loop/`)
consumes, the same as the family's other repos.

## Protocol

- `- [ ]` actionable — the planner may pick it up
- `- [b]` blocked — skipped, and excluded from the pending count
- `- [x]` completed — pruned on sight; the history lives in git

Effort S/M/L, impact ★ … ★★★.

## Open

- [ ] **spdlog is linked into `libAccelerANTgine.so` without PIC and with default
      visibility** [M, ★★]. `third_party/CMakeLists.txt` adds spdlog with
      `SPDLOG_BUILD_PIC` OFF. Its objects come out as PIE and are linked into a shared
      library whose own code is `CXX_VISIBILITY_PRESET hidden` (`Src/CMakeLists.txt`).
      GNU ld, lld and mold 3.0.0 accept that link, but only because they bind those
      symbols locally; mold 2.x refuses it with `R_X86_64_PC32 … recompile with -fPIC`.
      Measured in `:latest` on 2026-10-05 for OmniAccelerANT's linker evaluation:
      - With `SPDLOG_BUILD_PIC=ON`, mold 2.40.4 links, but the library exports 798
        dynamic symbols instead of 179, about 619 of them spdlog/fmt. The Debug build's
        `commitTestSuite` and `compileTestSuite` then abort at startup with an ASan
        odr-violation on `vtable for spdlog::spdlog_ex`.

      So PIC alone is the wrong half-fix. Build spdlog PIC **and** hidden: set
      `POSITION_INDEPENDENT_CODE ON`, `CXX_VISIBILITY_PRESET hidden` and
      `VISIBILITY_INLINES_HIDDEN ON` on the `spdlog` target, as the nlohmann and toml
      module targets are already PIC. Done when the Linux Release and Debug (ASan +
      UBSan) builds pass their suites with GNU ld, lld and mold 3. Also check that
      `nm -D --defined-only libAccelerANTgine.so` exports no `spdlog`/`fmt` symbol, and
      that OmniAccelerANT's native lane is green against the new pin. Windows is
      unaffected: PE has no PIC and no preemption.
