package sqlite

import "core:c"
import "core:math/bits"
import "core:strings"

// Open flags as bit positions matching sqlite3.h masks (bit N → 1<<N).
Open_Flag :: enum {
    Readonly     = 0, // 0x00000001
    Readwrite    = 1, // 0x00000002
    Create       = 2, // 0x00000004
    Uri          = 6, // 0x00000040
    Memory       = 7, // 0x00000080
    Nomutex      = 15, // 0x00008000
    Fullmutex    = 16, // 0x00010000
    Sharedcache  = 17, // 0x00020000
    Privatecache = 18, // 0x00040000
    Nofollow     = 24, // 0x01000000
}

Open_Flags :: bit_set[Open_Flag;u32]

// Default writer: read/write + create. Single-thread reactor: add `.Nomutex` at open if desired.
DEFAULT_WRITER :: Open_Flags{.Readwrite, .Create}
DEFAULT_READER :: Open_Flags{.Readonly}

// WAL checkpoint modes.
Checkpoint :: enum {
    Passive,
    Full,
    Restart,
    Truncate,
}

// True when `rc` is not a success outcome for a step-or-done style call.
is_error :: proc(rc: Result) -> bool {
    return rc != .Ok && rc != .Row && rc != .Done
}

libversion :: proc() -> string {
    return string(c_libversion())
}

libversion_number :: proc() -> int {
    return int(c_libversion_number())
}

// Open a database at `path`. On failure `db` is nil.
open :: proc(path: string, flags: Open_Flags = DEFAULT_WRITER) -> (db: ^Conn, rc: Result) {
    cpath, clone_err := strings.clone_to_cstring(path, context.temp_allocator)

    if clone_err != nil {
        return nil, .No_Mem
    }

    rc = c_open_v2(cpath, &db, c.int(transmute(u32)flags), nil)

    if rc != .Ok {
        if db != nil {
            _ = c_close_v2(db)
            db = nil
        }
    }

    return
}

// Open an in-memory database (`:memory:`).
open_memory :: proc(flags: Open_Flags = DEFAULT_WRITER) -> (db: ^Conn, rc: Result) {
    return open(":memory:", flags)
}

// Close a connection. Reports `.Busy` while a statement or blob still belongs to
// it, making leaked children observable. Safe on nil (returns `.Ok`).
close :: proc(db: ^Conn) -> Result {
    if db == nil {
        return .Ok
    }

    return c_close(db)
}

busy_timeout :: proc(db: ^Conn, ms: int) -> Result {
    assert(db != nil, "busy_timeout needs a connection")
    assert(ms >= 0, "busy_timeout ms must be non-negative")

    if ms > bits.I32_MAX {
        return .Range
    }

    return c_busy_timeout(db, c.int(ms))
}

// Run zero or more SQL statements with no bind parameters. Does not return rows.
exec :: proc(db: ^Conn, sql: string) -> Result {
    assert(db != nil, "exec needs a connection")

    csql, clone_err := strings.clone_to_cstring(sql, context.temp_allocator)

    if clone_err != nil {
        return .No_Mem
    }

    err_msg: cstring
    rc := c_exec(db, csql, nil, nil, &err_msg)

    if err_msg != nil {
        c_free(rawptr(err_msg))
    }

    return rc
}

// Prepare a single statement. Caller must `finalize` it.
prepare :: proc(db: ^Conn, sql: string) -> (stmt: ^Stmt, rc: Result) {
    assert(db != nil, "prepare needs a connection")
    assert(len(sql) > 0, "prepare needs non-empty sql")

    if len(sql) > bits.I32_MAX {
        return nil, .Too_Big
    }

    // SQLite accepts a counted, non-NUL-terminated buffer when nByte is exact.
    rc = c_prepare_v2(db, cstring(raw_data(sql)), c.int(len(sql)), &stmt, nil)

    if rc != .Ok {
        stmt = nil
    }

    return
}

finalize :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "finalize needs a statement")

    return c_finalize(stmt)
}

reset :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "reset needs a statement")

    return c_reset(stmt)
}

clear_bindings :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "clear_bindings needs a statement")

    return c_clear_bindings(stmt)
}

step :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "step needs a statement")

    return c_step(stmt)
}

// Bind a 1-based parameter as i64.
bind_i64 :: proc(stmt: ^Stmt, index: int, value: i64) -> Result {
    assert(stmt != nil, "bind_i64 needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX {
        return .Range
    }

    return c_bind_int64(stmt, c.int(index), value)
}

// Bind a 1-based parameter as f64.
bind_f64 :: proc(stmt: ^Stmt, index: int, value: f64) -> Result {
    assert(stmt != nil, "bind_f64 needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX {
        return .Range
    }

    return c_bind_double(stmt, c.int(index), value)
}

// Bind a 1-based parameter as UTF-8 text. Uses TRANSIENT so SQLite copies
// immediately; the Odin string need not outlive the call.
bind_text :: proc(stmt: ^Stmt, index: int, value: string) -> Result {
    assert(stmt != nil, "bind_text needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX {
        return .Range
    }

    if len(value) > bits.I32_MAX {
        return .Too_Big
    }

    if len(value) == 0 {
        return c_bind_text(stmt, c.int(index), "", 0, TRANSIENT)
    }

    return c_bind_text(stmt, c.int(index), cstring(raw_data(value)), c.int(len(value)), TRANSIENT)
}

// Bind a 1-based parameter as a blob. Uses TRANSIENT so SQLite copies.
bind_blob :: proc(stmt: ^Stmt, index: int, value: []byte) -> Result {
    assert(stmt != nil, "bind_blob needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX {
        return .Range
    }

    if len(value) > bits.I32_MAX {
        return .Too_Big
    }

    if len(value) == 0 {
        return c_bind_blob(stmt, c.int(index), nil, 0, TRANSIENT)
    }

    return c_bind_blob(stmt, c.int(index), raw_data(value), c.int(len(value)), TRANSIENT)
}

bind_null :: proc(stmt: ^Stmt, index: int) -> Result {
    assert(stmt != nil, "bind_null needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX {
        return .Range
    }

    return c_bind_null(stmt, c.int(index))
}

column_count :: proc(stmt: ^Stmt) -> int {
    assert(stmt != nil, "column_count needs a statement")

    return int(c_column_count(stmt))
}

column_type :: proc(stmt: ^Stmt, col: int) -> Type {
    assert(stmt != nil, "column_type needs a statement")
    assert(col >= 0, "column index is 0-based")

    return c_column_type(stmt, c.int(col))
}

column_i64 :: proc(stmt: ^Stmt, col: int) -> i64 {
    assert(stmt != nil, "column_i64 needs a statement")
    assert(col >= 0, "column index is 0-based")

    return c_column_int64(stmt, c.int(col))
}

column_f64 :: proc(stmt: ^Stmt, col: int) -> f64 {
    assert(stmt != nil, "column_f64 needs a statement")
    assert(col >= 0, "column index is 0-based")

    return c_column_double(stmt, c.int(col))
}

// Borrow the column as an Odin string view. Valid until the next call that
// invalidates the statement's row (step/reset/finalize) or re-reads columns.
column_text :: proc(stmt: ^Stmt, col: int) -> string {
    assert(stmt != nil, "column_text needs a statement")
    assert(col >= 0, "column index is 0-based")

    text := c_column_text(stmt, c.int(col))

    if text == nil {
        return ""
    }

    n := int(c_column_bytes(stmt, c.int(col)))

    if n <= 0 {
        return ""
    }

    return string((cast([^]byte)rawptr(text))[:n])
}

// Borrow the column as a byte slice. Same lifetime rules as column_text.
column_blob :: proc(stmt: ^Stmt, col: int) -> []byte {
    assert(stmt != nil, "column_blob needs a statement")
    assert(col >= 0, "column index is 0-based")

    n := int(c_column_bytes(stmt, c.int(col)))

    if n <= 0 {
        return nil
    }

    p := c_column_blob(stmt, c.int(col))

    if p == nil {
        return nil
    }

    return (cast([^]byte)p)[:n]
}

// English error message for the most recent failure on `db`. Empty if none.
// Borrowed until the next SQLite call on this connection.
errmsg :: proc(db: ^Conn) -> string {
    if db == nil {
        return ""
    }

    msg := c_errmsg(db)

    if msg == nil {
        return ""
    }

    return string(msg)
}

errcode :: proc(db: ^Conn) -> Result {
    assert(db != nil, "errcode needs a connection")

    return c_errcode(db)
}

// Extended result code for the most recent failure on `db`, as a raw integer.
// SQLite's set is open — newer headers add codes — so it is not modeled as a
// closed enum. Reduce it to its base family with `extended_result_base`.
extended_errcode :: proc(db: ^Conn) -> c.int {
    assert(db != nil, "extended_errcode needs a connection")

    return c_extended_errcode(db)
}

// Base `Result` family of an extended code: the low byte (code & 0xff).
extended_result_base :: proc(ext: c.int) -> Result {
    return Result(ext & 0xff)
}

changes :: proc(db: ^Conn) -> int {
    assert(db != nil, "changes needs a connection")

    return int(c_changes(db))
}

last_insert_rowid :: proc(db: ^Conn) -> i64 {
    assert(db != nil, "last_insert_rowid needs a connection")

    return c_last_insert_rowid(db)
}

// True when `db` is not inside an explicit transaction.
autocommit :: proc(db: ^Conn) -> bool {
    assert(db != nil, "autocommit needs a connection")

    return c_get_autocommit(db) != 0
}

// Run a WAL checkpoint. `nlog` / `nckpt` receive SQLite's frame counts when non-nil.
// Both are documented-undefined for a NULL `zDb` (this binding's only mode: all
// attached databases), and are -1 until `db` has run at least one statement against
// the schema, so a freshly opened connection needs a warm-up read first.
wal_checkpoint :: proc(db: ^Conn, mode: Checkpoint = .Passive, nlog: ^int = nil, nckpt: ^int = nil) -> Result {
    assert(db != nil, "wal_checkpoint needs a connection")

    e_mode: c.int

    switch mode {
    case .Passive:
        e_mode = 0

    case .Full:
        e_mode = 1

    case .Restart:
        e_mode = 2

    case .Truncate:
        e_mode = 3
    }

    cnlog, cnckpt: c.int
    pnlog: ^c.int = nil if nlog == nil else &cnlog
    pnckpt: ^c.int = nil if nckpt == nil else &cnckpt
    rc := c_wal_checkpoint_v2(db, nil, e_mode, pnlog, pnckpt)

    if nlog != nil {
        nlog^ = int(cnlog)
    }

    if nckpt != nil {
        nckpt^ = int(cnckpt)
    }

    return rc
}
