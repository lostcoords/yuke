# AGENTS.md

Correctness is required. Safety first, then performance, then ease of change.
Performance is a requirement, not a preference. See [Performance](#performance).
Do the work correctly the first time.

Write in ASD-STE100: one meaning per word, active voice, simple tense, one instruction per sentence.
Look up APIs on the internet and in this tree. Do not guess.

## Work

- While you work: `zig build test --seed 0`
- Before commit: `zig build test`
- `--seed 0` only sets the build graph order. It does not replace the full tests.

## Rules

- Use `std.debug.assert` for invariants. Types check structure. Asserts check logic and state.
- Show own and borrow in the type and the name.
- Keep function signatures small. Push control up. Push data down.
- Do not leave a known defect. Do not add code for a failure without evidence: a test, a log, a report, or a measurement.
- You can omit a feature. Do not ship a wrong feature.
- Prefer not to add a dependency, but you can discuss with the user.

## Performance

No regressions in time, memory, or allocations. A slower hot path is a defect, including cleanup.

Hot paths: draw, input, stream delivery, per-frame, per-row. Do not add allocation, closure, call, or `await`. QuickJS: each object, closure, and private field costs time.

QuickJS on a hot path:
- `for...of` allocates one iterator per loop. Over a short array, use an index loop (27% faster in a probe).
- `for (const [k, v] of map)` allocates one array per entry (10× slower). Use `map.forEach`, `map.values()`, or `map.keys()`.
- A call sets up every local of the function before the first statement, also when the function returns early. Keep a common early exit, such as a cache hit, in a function with few locals. Move the rare path into its own method (`style.resolve` and `_build`: 11% faster).
- An object gets its shape from its fields and their order. Give objects of one kind the same fields in the same order. Do not add a field that most objects do not need (`stop` on each text row: +1.4% on `rows()`).
- Two dictionary objects that get the same keys in the same order share one shape. Then each new key copies the whole shape. Use a `Map` for a private dictionary (`style._base`).

When you change the JS host, engine, or renderer, measure vs base:
`zig build bench -Doptimize=ReleaseFast -- --fixture bench/transcript-fixture.json`
Add `-Dmetrics=true` for allocs (separate run). One phase: `--phase <name> --iterations 3000`.

Time noise ~20%: 5+ runs each side, alternate, lowest quartile. Alloc count and live/peak bytes are exact. If a phase is worse, stop and say why.

For a small delta, count instructions with callgrind (build with `-Dcpu=baseline`). Compare the slope between two iteration counts, not the totals: setup fills a short run. GC and heap layout move one window, so check a second window before you call a delta real.

## Memory

- `gpa` lives with the owner. The caller frees it, or the owner calls `deinit`.
- `arena` lives for one scope. Do not keep a pointer after that scope ends.
- Name the parameter `gpa` or `arena`.
- Copy across a lifetime with `proto.dupe`. Do not share the pointer.
- Do not allocate on a hot path if a buffer or an arena is already there.

## I/O

- The process starts one `zio.Runtime` with `executors = .exact(1)`.
- That runtime is the only reactor. It uses one thread.
- Pass `std.Io` to every function that waits, reads, writes, or reads time.
- Do not pass `zio` types through library code.
- Only the JavaScript host owner enters QuickJS.

## Code

- Put `//!` on the file.
- Put `///` on each public declaration. Say what it is, who owns the bytes, and why it fails.
- A `//` comment is one line. State the invariant.
- Use `unreachable` only when a check already made the case impossible. Write why on that line.
- Write explicit error sets. Do not hide `error.OutOfMemory`.
- Do not add a function that only forwards a call.
- Do not add a type that only wraps one field with no new meaning.
- If you use logic once, put it at the call site.

## Plugin API

- Put a `/** */` summary on each public JS export: what it is, what null means, why it throws. `mise run types` fails without one.
- A change to the public JS API also updates `docs/` in the same commit. Keep `docs/examples` passing `mise run check-ts`.

## Tests

- Do not add a test that restates a type, a constant, or removed logic.
- Add a test only to pin an invariant.
- One focused test is better than many equivalent cases.

## Generated files

If you change the source of a generated file, regenerate it and stage the output.
