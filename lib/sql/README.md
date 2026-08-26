# sql

`sql` is yuke's strict typed layer over zqlite. SQLite still parses and executes SQL; Zig
comptime specializes binding, row decoding, ownership, and generated query APIs.

Queries live in `*.sql` files:

```sql
-- name: ReadWidget :optional
-- id: wire.ids.SessionId!
-- name: []const u8!
SELECT id, name FROM widget WHERE id = :id;
```

The cardinality is one of `:exec`, `:one`, `:optional`, or `:many`. A trailing `!` makes an
annotated value non-null; without it the generated field is `?T`. Every named parameter needs an
annotation. INTEGER and computed result columns need annotations too, because SQLite cannot tell
the generator their Zig signedness or semantic type. Plain TEXT, BLOB, and REAL result columns can
fall back to `[]const u8`, `sql.Blob`, and `f64`.

Generate and check the committed output with:

```sh
zig build sqlgen -- \
  --migrations path/to/migrations \
  --queries path/to/queries \
  --queries-out path/to/queries_gen.zig

zig build sqlgen -- \
  --migrations path/to/migrations \
  --queries path/to/queries \
  --queries-out path/to/queries_gen.zig \
  --check
```

The tool applies migrations in filename order to an in-memory database and asks SQLite to prepare
every query. The generated registry prepares once and owns all statements:

```zig
var queries = try queries_gen.Queries.prepareAll(conn);
defer queries.deinit();

try queries.insert_widget.exec(.{ .id = id, .name = name });

var widget = (try queries.read_widget.maybeOne(allocator, .{ .id = id })) orelse return error.NotFound;
defer widget.deinit();
```

Text and dynamic BLOB fields in returned rows are owned by the allocator passed to `one`,
`maybeOne`, or `Rows.next`; call `deinit` on every returned row. Prepared queries and active row
iterators are unique owners and must not be copied.
