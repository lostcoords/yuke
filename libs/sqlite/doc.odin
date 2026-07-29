/*
package sqlite is a minimal Odin wrapper around libsqlite3.

Public API uses `string`, `int`, `[]byte`, and `i64` — not `cstring` / `c.int`.
The raw C FFI lives in `c.odin` as `@(private)` `c_*` procedures; importers
cannot see or call them.

Batteries included: open/close, prepare/bind/step, exec, busy_timeout,
autocommit, WAL checkpoint, extended result codes.

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
