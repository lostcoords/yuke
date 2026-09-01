# yuke — Agent Context

Zig implementation of the yuke wire protocol, being rewritten **from zero** in Zig 0.16 on the
orphan `zig` branch. `main` holds the previous Odin implementation and stays as migration
reference — do not delete it or silently restore behavior from it without a task saying so.
The odin code MUST be improved. You are encouraged to do LOTS of web research.

The project is **pre-release**: backwards compatibility is not a constraint. Prioritize better
code. Protocol changes must still be deliberate and coordinated, never accidental drift.

## Source of truth

- **`lib/wire/` (the Zig types) is authoritative.** `schema/wire.json` is GENERATED from them by
  `tools/wiregen` (`zig build gen-schema`). It feeds downstream SDK generators (e.g. `../yuke-ts-sdk`).
- Tests define the accepted and rejected encodings. Preserve both positive behavior and strict
  rejection.
- Keep closed protocol sets closed. But do suggest improvements if there is a clear one. Discuss with the user.

## Commands

- `zig build test` runs the wire tests. `mise` pins Zig 0.16.0 (`.mise.toml`).
- `zig build test-js` runs the TUI QuickJS host (`src/tui/host.zig` and imports).
- `zig build` installs `yuke`. Default mode is the TUI. `yuke --daemon` starts the server.
- `zig build` installs `yuke`. Default mode is the TUI. `yuke --daemon` starts the server.
- Run `zig fmt` after changing sources; keep tests green. Never forget.

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
