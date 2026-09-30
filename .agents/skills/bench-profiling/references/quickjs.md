# QuickJS-ng cost mechanisms

Each point below has evidence: a line in the vendored engine (`zig-pkg/*/quickjs.c`, QuickJS-ng 0.16) or a yuke measurement. Line numbers drift with engine updates; search for the named function.

## Contents
- Engine facts
- Call cost: locals
- Object shapes
- Iterators
- Tools the engine offers
- Findings log

## Engine facts

- QuickJS-ng is a bytecode interpreter with computed-goto dispatch. It has no JIT.
- It has no inline caches. QuickJS-ng removed them in 0.9.0 ([PR #884](https://github.com/quickjs-ng/quickjs/pull/884)). Each property read is a shape hash lookup (`find_own_property`).
- callgrind shows interpreted JS only as `JS_CallInternal` self cost, and property reads as `JS_GetPropertyInternal`. Use regions or `fndiff.py --opcodes` to see further.
- `a + b` copies both strings when `b` has at most 512 characters and `a` at most 8192 (`JS_STRING_ROPE_SHORT_LEN`, `JS_STRING_ROPE_SHORT2_LEN`). Otherwise it makes a rope node and copies nothing. A rope whose left side is short copies the string before it when you append the rope, so a join of many ropes can copy the joined string again at each step.
- `term.wrap` converts the whole JS string to UTF-8 before it applies the row limit. A wrap for one row of a large text costs a copy of the whole text.

## Call cost: locals

`JS_CallInternal` allocates a frame and sets every local to `undefined` before the first opcode (the `var_buf` loop after the `alloca`). Each `let` or `const` also gets one `OP_set_loc_uninitialized` when its scope starts, and the function body is a scope. The return path frees every local. An early `return` skips none of this.

Evidence (2026-09-30, `stream_native`, region around `style.resolve`): the version with ten miss-path locals cost 183.2M instructions against 163.7M for the old code. A `{ }` block around the miss path gave 166.7M. Moving the miss path into its own method gave 145.0M. `fndiff.py --opcodes` on that region shows the cause directly: `(prologue)` +13.0M, `(epilogue)` +2.9M, `OP_set_loc_uninitialized` +1.4M.

Fix: keep the common exit of a hot function (a cache hit, an unchanged check) in a function with few locals. Move the rare path into its own method.

## Object shapes

A shape is the list of an object's fields in order. Objects with the same fields in the same order share one shape through the shape hash table (`add_property`, `find_hashed_shape_prop`).

- Adding a field to an object whose shape is shared, when no cached transition exists, clones the shape (`js_clone_shape`). A field that most objects of one kind lack makes extra shapes and copies. Evidence: `stop: rows.length === 0` on every text row cost +1.4% on `Transcript.rows()`.
- Two dictionary objects that get the same keys in the same order share one shape. Each new key then finds the shape shared and copies it, so the cost grows with the key count. Evidence: `style._base` and `style.groups` as parallel `Object.create(null)` dictionaries; making `_base` a `Map` cut style registration from 45.6M to 39.2M.
- A long-lived empty object `{}` keeps the empty `Object.prototype` shape alive and shared. Each new object literal then clones that shape on its first field, where it would otherwise build a private one (`js_new_shape2`). This depends on the whole heap, not on the code under test. Evidence: removing three long-lived `{}` moved the `stream` phase by 0.2%. The real app keeps such objects (for example `mcp.js` `META`), so a bench delta from this is a bench artifact.

## Iterators

- `for...of` calls `js_for_of_start`, which allocates one iterator object per loop and looks up `next`. Over a short array, an index loop was 27% faster in a probe.
- `for (const [k, v] of map)` also allocates one array per entry, about 10× slower. Use `map.forEach`, `map.values()`, or `map.keys()`.

## Tools the engine offers

- No profiler. QuickJS-ng 0.16 and 0.17 have no function or sampling profiler.
- `JS_SetDumpFlags` and the `JS_DUMP_*` flags work only without `NDEBUG`. Zig defines `NDEBUG` for C in ReleaseFast, so the bench has none of them.
- `JS_ComputeMemoryUsage` is always present. The bench reports two of its fields as `js_estimated_bytes` and `js_tracked_bytes`. Its object, shape, and string counts show shape growth between two points.

## Findings log

Add a finding here with its evidence: the phase, the region, the numbers, and the fix. Add the one-line rule to the QuickJS list in `AGENTS.md`.

| Date | Finding | Evidence | Fix |
|---|---|---|---|
| 2026-09-29 | `for...of` iterator per loop | index loop 27% faster (probe) | index loops on hot paths |
| 2026-09-30 | locals set up before an early return | `resolve` region 183.2M → 145.0M | split the miss path |
| 2026-09-30 | a field most rows lack | `rows()` +1.4% | `stop` only on the first row |
| 2026-09-30 | parallel dictionaries share a shape | style registration 45.6M → 39.2M | `_base` as a `Map` |
| 2026-09-30 | long-lived empty `{}` | `stream` +0.2%, bench only | none; the app keeps such objects |
| 2026-09-30 | a one-row wrap of a whole file | folded `read` source: `build` +52 MB allocated per 300 iterations | a zero row cap passes limit 0, so `wrapRows` returns before the native wrap |
| 2026-09-30 | the message source joined on each build | `build` 909 → 805 allocs/it, `preview` 30.7 → 21.2, `reflow` 550 → 498 (with the fix above) | `partBases` from a running length; `_sourceOf` joins on the first read |
