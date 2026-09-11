# yuke — Agent Context

The project is **pre-release**: backwards compatibility is not a constraint. Prioritize better
code. Protocol changes must still be deliberate and coordinated, never accidental drift.

## Source of truth

- **`lib/proto/` (the Zig types) is authoritative.** `schema/proto.json` is generated from them by
  `tools/protogen` (`zig build gen-schema`). It feeds downstream SDK generators (for example, `../yuke-ts-sdk`).
- Tests define the accepted and rejected encodings. Preserve both positive behavior and strict
  rejection.
- Keep closed protocol sets closed. But do suggest improvements if there is a clear one. Discuss with the user.

## Commands

- `zig build test` runs the full test suite. `mise` pins Zig 0.16.0 (`.mise.toml`).
- For the edit loop, run `zig build test --seed 0 --summary new`. A fixed seed lets an unchanged test
  binary reuse its passing result. `--summary new` lists only the steps that ran. CI keeps the random
  seed and runs every test again.
- `zig build test-js` runs the unified process and QuickJS host tests (`src/tests.zig`).
- `zig build` installs `yuke`. The default mode is the TUI. `yuke --rpc` selects the JSONL RPC frontend.
- Run `zig fmt` after changing sources; keep tests green. Never forget.

## Performance and allocations

- Analyze allocation cost for each change to a hot path, a cache, or data ownership. Verify library behavior from the source.
- For changes to UI or JS host performance, compare the same benchmark scenario before and after the change with `zig build bench -Doptimize=ReleaseFast -Dmetrics=true`.
- Use allocation/free counts, byte totals, resize/remap attempts, live/peak bytes, and UI work counters. Live bytes alone do not show temporary allocation cost.
- Measure latency separately with `zig build bench -Doptimize=ReleaseFast`. Metrics add overhead. Tests enable the counters automatically.
- The benchmark tracks native Zig allocations and QuickJS backing allocations through the host and renderer allocator. It excludes allocations outside that allocator, such as the benchmark output buffer.
- The flag does not instrument all Zig code. For a path outside the harness, use a relevant allocation counter or benchmark. State any gap in coverage.
- QuickJS can serve small allocations from internal arenas. The counters measure backing allocations, not every JS object or string allocation. Zero backing allocations do not prove zero JS allocation work.
- Separate setup and cache warmup from repeated work. Measure fresh values separately from reused values when that distinction affects the cost.
- Report the scenario, commands, and before/after evidence. Do not claim zero allocations or a performance gain without measurements. See `bench/README.md`.

## Zig style

- Follow the conventions of the Zig standard library, Ghostty, and TigerBeetle.
- Naming is **Zig**: `TitleCase` types (no underscores — `SessionScope`, not the contract's
  `Session_Scope`), `camelCase` functions, `snake_case` fields and variables, `SCREAMING_SNAKE_CASE`
  or `snake_case` module-level constants per std usage.
- Keep comments minimal: protocol semantics, ownership, invariants, non-obvious rationale. Never
  narrate self-evident syntax.
- Every comment is ONE line. Never two, never a block. This covers `///`, `//!`, `//`, and SQL.
  Cut the second sentence; do not wrap it onto a second line.
- Write all English (comments, docs, commits) in ASD-STE100 Simplified Technical English:
  active voice; present/past/future tense (no -ing); one idea per sentence; short sentences;
  keep the articles; consistent terms; keep technical names.

## Assertions (TigerBeetle discipline)

- Assert liberally. Every procedure over internal state checks its arguments, key invariants, and
  impossible branches — a couple of assertions per proc, positive space and negative space.
- Assertions guard **already-validated internal state**: state transitions, offsets, ordering,
  finalization, ownership. A failed assertion is a bug in our code — fail fast.
- **Never assert on wire or peer input.** A malformed frame returns an error and degrades
  gracefully; it must never crash. Keep the decode boundary error-return-based; assert on the
  other side of it.
- A condition is either a programmer error or an operating error, never both: assert it or handle
  it, not both.

## Design (TigerBeetle "zero technical debt")

- Do it right the first time; the second pass may never happen. Don't knowingly leave temporary
  fixes, deferred correctness, or cleanup debt inside the requested scope. (Deliberately staged
  work — e.g. validation as a later pass — is fine when named as such, not smuggled in.)
- Prefer concrete, direct code over speculative layers. Extract a helper when it removes real
  duplication or names a non-obvious invariant, not for hypothetical reuse.
- Verify external facts (library behavior, an API, a spec detail) by reading the source or
  searching. Do not assume.

## Collaboration

- Maintain active, detailed dialogue: what's changing, the invariants and lifetimes, the risky
  paths checked, and the evidence for each conclusion. Surface assumptions, uncertainty, and
  tradeoffs as soon as they matter. Do not declare work complete while relevant uncertainty
  remains; the final handoff explains what changed, why it is correct, and how it was verified.

## Commit

- Do not add a Claude co-author trailer.
- Never add a Claude session trailer.
- Keep commit messages short: two lines maximum.
