/*
package sqlite is a minimal, Odin-facing SQLite3 wrapper for the yuke daemon store.

Public API uses `string`, `int`, `[]byte`, and `i64` — not `cstring` / `c.int`.
The raw C FFI lives in `c.odin` as `@(private)` `c_*` procedures; importers of
`libs:sqlite` cannot see or call them.

It is not a general-purpose ORM: only the surface the store needs (open,
prepare/bind/step, exec, busy_timeout, WAL checkpoint). Schema, writer/reader
policy, and yuke tables live in the daemon — not here.

Linking:
  - Darwin / Linux: system `libsqlite3`.
  - Windows: static archive from the official amalgamation
    (`libs/sqlite/bin/sqlite3.lib`). See `amalgamation/README.md` and
    `make sqlite-static`.

Column text/blob slices returned by this package are **borrowed**: valid only
until the next API call on the same statement or connection (step, reset,
finalize, close). Clone if the value must outlive the next call.
*/
package sqlite
