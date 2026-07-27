/*
package quickjs is a minimal, Odin-facing QuickJS-NG wrapper for the yuke daemon's
scripting tier.

Public API uses `string`, `int`, and `bool` — not `cstring` / `c.int`. The raw C
FFI lives in `c.odin` as `@(private)` `c_*` procedures; importers of
`libs:quickjs` cannot see or call them.

It is not a general-purpose JS host: only the surface the daemon needs (runtime
and context lifetime, eval/call, host procedures, property access, promises,
and the three resource controls below). Module loaders, classes, typed arrays,
and bytecode serialization are deliberately absent.

QuickJS declares 34 of its API entry points as `static inline`, so they have no
exported symbols. `value.odin` reimplements them against the `Value` layout that
`c.odin` asserts.

Linking: every target needs a static archive built from the pinned amalgamation
(`bin/<os>_<arch>/quickjs.{a,lib}`). Unlike `libs:sqlite` there is no system
library to fall back on for any platform. See `amalgamation/README.md` and
`make quickjs-static`.

Three controls make a runtime safe to host untrusted script per session:
  - `runtime_new` with an `Alloc_Functions` binds the VM to a caller-owned
    arena, so eviction reclaims in one shot.
  - `set_memory_limit` caps allocation; overrun raises instead of aborting.
  - `set_interrupt_handler` reclaims the thread from a runaway turn. It cannot
    interrupt a single long-running engine builtin.

Ownership: values returned by this package are **owned** — release them with
`free_value`. Strings from `to_string` are **borrowed** from the engine and are
valid only until `free_string`. `set_property` and `set_index` **consume** the
value passed to them.
*/
package quickjs
