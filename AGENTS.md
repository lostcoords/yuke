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
- Do not leave a known defect.
- You can omit a feature. Do not ship a wrong feature.
- Prefer not to add a dependency, but you can discuss with the user.

## Performance

- Each change keeps or improves time, memory use, and the allocation count.
- A slower hot path is a defect, also in a cleanup.
- Hot paths are draw, input, stream delivery, and per-frame or per-row work.
- On a hot path, do not add an allocation, a closure, a call, or an `await`.
- In QuickJS, each object, closure, and private field costs time. Count them.
- Measure each change to the JavaScript host, the engine, or the renderer. Compare the base commit with your commit.
- Time: `zig build bench -Doptimize=ReleaseFast -- --fixture bench/transcript-fixture.json`
- Memory and allocations: add `-Dmetrics=true` in a separate run.
- One phase: add `--phase <name> --iterations 3000`.
- A timing changes by up to 20% between runs. Run each side 5 times or more, alternate the sides, and compare the lowest quartile.
- The allocation count and the live and peak bytes are exact. Compare them per phase.
- Report the result. If a phase gets worse, stop and tell the user why.

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

## Tests

- Do not add a test that restates a type, a constant, or removed logic.
- Add a test only to pin an invariant.
- One focused test is better than many equivalent cases.

## Generated files

If you change the source of a generated file, regenerate it and stage the output.
