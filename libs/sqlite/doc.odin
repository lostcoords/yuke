/*
package sqlite is a minimal wrapper around libsqlite3. See `README.md` for usage.

The API uses Odin types where it can and C types where it has to; check the
signatures. The raw FFI lives in `c.odin` as `@(private)` `c_*` procedures, so
importers cannot reach it.

Failure is always a `Result` from SQLite; this binding invents no error categories.
`Scan_Error` and `Bind_Error` are the exceptions: they describe a statement's shape
against a struct, not execution. Assertions cover caller bugs the C API would answer
with undefined behavior, like a nil handle or a zero parameter index. Anything
SQLite decides is returned.

`scan` and `bind` are one idea in two directions: resolve a struct against a
statement once, then move rows through the resolved mapping. Names bind, not
positions, so neither call site depends on the order of columns or markers in the
SQL. Only scanning carries an allocator, because only scanning takes ownership.

The caller owns statement lifecycle; scanning never steps, resets, clears, or
finalizes. Text and blobs from `column_*` are borrowed and die with the row. A scan
clones them unless the field is tagged borrowed. Standalone binding makes SQLite
copy text and blobs. A mapped `execute` instead borrows them through its immediate
step and clears the bindings before returning, so its parameter struct may still be
a temporary.

Linking:
  - Darwin / Linux: system `libsqlite3`.
  - Windows: static archive from the official amalgamation
*/
package sqlite
