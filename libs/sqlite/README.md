# libs/sqlite

A thin Odin binding to libsqlite3. Most procs are one-line wrappers around
`sqlite3_*`.

## Connection

`open` takes a nul-terminated path. Default flags are `{.Readwrite, .Create}`
(`DEFAULT_WRITER`); readers get `{.Readonly}`. Add `.Nomutex` if the caller is
single-threaded.

```odin
db, _ := sqlite.open("store.db", {.Readwrite, .Create, .Nomutex})
defer sqlite.close(db)

sqlite.busy_timeout(db, 1000) or_return  // wait up to 1s on a locked table
```

## Journal, durability, checkpoint

SQLite settles these on its own instead of failing, so read back what you asked
for. `journal_mode_set` returns `settled = false` if the mode was refused;
`synchronous_set` reports nothing, so check it with `synchronous`.

```odin
settled := sqlite.journal_mode_set(db, .Wal) or_return
if !settled { return .Error }

sqlite.synchronous_set(db, .Normal) or_return
level := sqlite.synchronous(db) or_return
if level != .Normal { return .Error }

sqlite.wal_checkpoint(db, .Truncate) or_return
```

`wal_checkpoint` can report frame counts. They stay -1 until the connection has
run a statement against the schema.

## Transactions

`.Deferred` upgrades on the first write and gets `.Busy` immediately, ignoring
`busy_timeout`, so writers want `.Immediate`. There is no nesting: `txn_begin`
inside a transaction returns `.Error`.

```odin
write :: proc(db: ^sqlite.Conn) -> (rc: sqlite.Result) {
    sqlite.txn_begin(db, .Immediate) or_return

    // A failed ROLLBACK leaves the transaction open past this call, so it
    // replaces the original failure instead of being dropped.
    defer if rc != .Ok {
        if rollback := sqlite.txn_rollback(db); rollback != .Ok {
            rc = rollback
        }
    }

    sqlite.txn_commit(db) or_return

    return .Ok
}
```

A failed `txn_commit` may or may not have rolled back already. `txn_rollback` is
idempotent, so run it either way.

## Statements

Parameters are 1-based. `bind_text` and `bind_blob` pass SQLITE_TRANSIENT, so the
Odin value does not need to outlive the call.

```odin
st, _ := sqlite.prepare(db, "INSERT INTO events(session_id, seq, payload) VALUES(?1, ?2, ?3)")
defer sqlite.finalize(st)

sqlite.bind_text(st, 1, "sess-a") or_return
sqlite.bind_i64 (st, 2, 1)        or_return
sqlite.bind_text(st, 3, payload)  or_return
sqlite.execute(st)                or_return
```

`execute` steps once expecting `.Done`, then resets and clears. It resets even
when the step failed, so the statement stays reusable. `.Row` back from it means
the statement should have been `step`ped.

## Binding a struct

Positional indices couple every call site to the order of the markers in the SQL.
Name the parameters instead and resolve a struct against them once with
`bind_prepare`; a field binds to the marker that shares its name, so declaration
order is free. The mapping is closed in both directions — every field feeds a
marker and every marker is fed by a field — so a statement that drifts away from
its struct fails at `bind_prepare` rather than writing a wrong column.

`sql:"name"` renames a field and `sql:"-"` skips it, as when scanning. A scan's
`optional` and `borrowed` mean nothing on the way in and are refused. Enums bind
as their discriminant; a value stored as text keeps its conversion at the call
site. A mapping allocates nothing and needs no teardown, but it belongs to its
statement and must not outlive it.

```odin
Params :: struct {
    session_id: [16]u8,
    seq:        u64,
    payload:    string,
}

st, _ := sqlite.prepare(db, `INSERT INTO events(session_id, seq, payload)
    VALUES (:session_id, :seq, :payload)`)
defer sqlite.finalize(st)

mapping, err := sqlite.bind_prepare(st, Params)
if err != .None { return err }

sqlite.execute(&mapping, &Params{session_id = sid, seq = 1, payload = payload}) or_return
```

`execute` on a mapping binds and steps as one call, and resets on every path
including a failed bind. It borrows text and blobs only through that immediate
step and clears every binding before returning, avoiding SQLite's transient
copies. Use `bind` on its own for a statement that yields rows; that path copies
text and blobs before returning, then you drive `step` yourself.

`query_one_i64` and `query_one_text` do prepare/step/finalize in one call. They
bind nothing, so the SQL must be self-contained. `.Done` means no row, `.Row` a
second one, `.Mismatch` a wrong storage class.

```odin
high, rc := sqlite.query_one_i64(db, "SELECT max(seq) FROM events")
```

## Reading columns

Columns are 0-based and read off the current row. Text and blobs are borrowed
until the next `step` / `reset` / `finalize`.

```odin
for rc = sqlite.step(st); rc == .Row; rc = sqlite.step(st) {
    label := sqlite.column_text(st, 0) or_return // borrowed
    count := sqlite.column_i64(st, 1)            // owned
}
```

## Scanning

`scan_row` fills a struct from the current row. Fields match column names;
`sql:"column"` renames, `sql:",optional"` allows a missing column, `sql:"-"`
leaves a field untouched, `using` flattens a nested struct. Storage classes must
match exactly and narrowing is checked. A destination may be reused only after
`scan_destroy`; scan-managed strings and slices must be empty at entry.

```odin
Row :: struct {
    session: string `sql:"session_id"`,
    seq:     i64,
    payload: string,
}

for rc := sqlite.step(st); rc == .Row; rc = sqlite.step(st) {
    row: Row
    err := sqlite.scan_row(st, &row, context.allocator)
    if err != .None { return err }
    defer sqlite.scan_destroy(&row, context.allocator)

    consume(row.payload)
}
```

In a hot loop, resolve the shape once with `scan_prepare` and scan through the
mapping; a mapping scans only the type it was prepared for, which the compiler
checks. Free the mapping before finalizing its statement.

```odin
mapping, err := sqlite.scan_prepare(st, Row, context.allocator)
if err != .None { return err }
defer sqlite.scan_mapping_destroy(&mapping, context.allocator)

for sqlite.step(st) == .Row {
    row: Row
    err := sqlite.scan(&mapping, &row, context.allocator)
    // ownership as above: scan_destroy
}
```

`scan` and `bind` are the two directions of the same mapping idea: both resolve a
struct against one statement up front and both take the struct by pointer. Only
scanning needs an allocator, because only scanning takes ownership of memory
SQLite would otherwise reclaim at the next `step`.

## Owned vs borrowed

Scanned text and blobs are cloned into the allocator by default and freed by
`scan_destroy`. A field tagged `sql:",borrowed"` instead points at SQLite's own
column memory; `scan_destroy` blanks it without freeing.

```odin
Row :: struct {
    peek: string `sql:",borrowed"`,  // dies at the next step on `st`
    keep: string,                    // owned
}
```

A borrowed field must be consumed inside the row that produced it. Anything kept
past the row has to be owned or cloned. Only `string` and `[]byte` may borrow;
the tag is rejected elsewhere.

## Errors

`Result` (`c.odin`) is SQLite's primary result codes. `.Ok`, `.Row`, and `.Done`
are not failures; `is_error` tests the rest. Extended codes are an open set, so
`extended_errcode` returns a raw `c.int` and `extended_result_base` reduces it to
a `Result`.

`Scan_Error` (`scan.odin`) covers everything that stops a row from
materializing: a bad `sql` tag, an unsupported field type, a missing, unknown, or
duplicate column, a storage-class mismatch, NULL into a non-nullable field, a
value that does not fit (narrowing, unknown enum value, wrong-length fixed
blob), and a failed clone.

`Bind_Error` (`bind.odin`) covers everything that stops a struct from resolving
against a statement's parameters: a bad `sql` tag or one only a scan can honor, an
unsupported field type, a field no marker names, a marker no field feeds, two
fields racing for one marker, an ordinal `?` / `?NNN` marker, and a struct or
statement carrying more than `BIND_MAX_PARAMS` parameters. Every one of them is a
statement/struct pairing that a caller compiled in, so they surface at
`bind_prepare` and never during a write.

`errmsg(db)` is the English message for the last failure, borrowed until the next
call on `db`.
