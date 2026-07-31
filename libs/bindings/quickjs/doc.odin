/*
package quickjs is a minimal, Odin-facing QuickJS-NG wrapper.

Public API uses `string`, `int`, and `bool` — not `cstring` / `c.int`. The exceptions
are `eval` and the function constructors, whose `cstring` arguments must be
nul-terminated. The raw C FFI lives in `c.odin` as `@(private)` `c_*` procedures;
importers of `libs:bindings/quickjs` cannot see or call them.

Linking: every target needs a static archive built from the pinned
amalgamation (`bin/<os>_<arch>/quickjs.{a,lib}`). Unlike `libs:bindings/sqlite` there
is no system library to fall back on for any platform.

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
