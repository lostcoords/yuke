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

// Durability levels for `PRAGMA synchronous`. The discriminants are the integers
// the pragma reports; they come from the pragma reference, not `sqlite3.h`.
Synchronous :: enum i64 {
    Off    = 0,
    Normal = 1,
    Full   = 2,
    Extra  = 3,
}

// A pragma rejects bound parameters, so each level is a whole statement.
@(private, rodata)
synchronous_sql := [Synchronous]string {
    .Off    = "PRAGMA synchronous=OFF",
    .Normal = "PRAGMA synchronous=NORMAL",
    .Full   = "PRAGMA synchronous=FULL",
    .Extra  = "PRAGMA synchronous=EXTRA",
}

// Locking behavior of a BEGIN. `Deferred` upgrades on first write and gets
// `.Busy` at once without consulting `busy_timeout`; a writer wants `Immediate`.
Transaction_Behavior :: enum {
    Deferred,
    Immediate,
    Exclusive,
}

@(private, rodata)
txn_begin_sql := [Transaction_Behavior]string {
    .Deferred  = "BEGIN DEFERRED",
    .Immediate = "BEGIN IMMEDIATE",
    .Exclusive = "BEGIN EXCLUSIVE",
}

// Journal modes for `PRAGMA journal_mode`, which reports itself as text rather
// than an integer.
Journal_Mode :: enum {
    Delete,
    Truncate,
    Persist,
    Memory,
    Wal,
    Off,
}

@(private, rodata)
journal_mode_sql := [Journal_Mode]string {
    .Delete   = "PRAGMA journal_mode=DELETE",
    .Truncate = "PRAGMA journal_mode=TRUNCATE",
    .Persist  = "PRAGMA journal_mode=PERSIST",
    .Memory   = "PRAGMA journal_mode=MEMORY",
    .Wal      = "PRAGMA journal_mode=WAL",
    .Off      = "PRAGMA journal_mode=OFF",
}

// The mode the pragma reports back, always lower case whatever the request used.
@(private, rodata)
journal_mode_wire := [Journal_Mode]string {
    .Delete   = "delete",
    .Truncate = "truncate",
    .Persist  = "persist",
    .Memory   = "memory",
    .Wal      = "wal",
    .Off      = "off",
}

@(private, rodata)
empty_blob_sentinel := byte(0)

@(private)
Bind_Lifetime :: enum {
    Transient,
    Statement,
}

// True when `rc` is not a success outcome for a step-or-done style call.
is_error :: proc(rc: Result) -> bool {
    return rc != .Ok && rc != .Row && rc != .Done
}

// Return the runtime SQLite library version string.
libversion :: proc() -> string {
    return string(c_libversion())
}

// Return the runtime SQLite library version as an integer (XYYZZ).
libversion_number :: proc() -> int {
    return int(c_libversion_number())
}

// Open a database at `path`, which must be nul-terminated. On failure `db` is nil.
@(require_results)
open :: proc(path: cstring, flags: Open_Flags = DEFAULT_WRITER) -> (db: ^Conn, rc: Result) {
    assert(path != nil, "open needs a path")
    rc = c_open_v2(path, &db, c.int(transmute(u32)flags), nil)

    // SQLite hands back a live handle even on error, so a failed open must close it here.
    if rc != .Ok && db != nil {
        _ = c_close_v2(db)
        db = nil
    }

    return
}

// Open an in-memory database (`:memory:`).
@(require_results)
open_memory :: proc(flags: Open_Flags = DEFAULT_WRITER) -> (db: ^Conn, rc: Result) {
    return open(":memory:", flags)
}

// Close a connection. Reports `.Busy` while a statement or blob still belongs to
// it, making leaked children observable. Safe on nil (returns `.Ok`).
close :: proc(db: ^Conn) -> Result {
    if db == nil do return .Ok

    return c_close(db)
}

// Set how long SQLite waits for a locked table before returning `.Busy`.
busy_timeout :: proc(db: ^Conn, ms: int) -> Result {
    assert(db != nil, "busy_timeout needs a connection")
    assert(ms >= 0, "busy_timeout ms must be non-negative")

    if ms > bits.I32_MAX do return .Range

    return c_busy_timeout(db, c.int(ms))
}

// Request a journal mode. WAL is refused on some filesystems, and the pragma
// reports the mode it settled on rather than failing, so `settled` can be false.
journal_mode_set :: proc(db: ^Conn, mode: Journal_Mode) -> (settled: bool, rc: Result) {
    assert(db != nil, "journal_mode_set needs a connection")

    stmt: ^Stmt
    stmt, rc = prepare(db, journal_mode_sql[mode])

    if rc != .Ok do return false, rc
    defer finalize(stmt)
    assert(column_count(stmt) == 1, "PRAGMA journal_mode reports one column")

    rc = step(stmt)

    if is_error(rc) do return false, rc

    assert(rc == .Row, "PRAGMA journal_mode always reports a mode")

    // A mode this binding does not name is not the one asked for, so an added
    // SQLite mode degrades to `settled = false` instead of asserting.
    reported, column_rc := column_text(stmt, 0)
    if column_rc != .Ok do return false, column_rc

    return reported == journal_mode_wire[mode], .Ok
}

// Request a durability level. SQLite can settle elsewhere and says so only when
// read back, so a caller depending on the level must confirm it with `synchronous`.
synchronous_set :: proc(db: ^Conn, level: Synchronous) -> Result {
    assert(db != nil, "synchronous_set needs a connection")
    return exec(db, synchronous_sql[level])
}

// Report the connection's durability level. `rc` is `.Ok` or a failure, and
// `level` is meaningful only when it is `.Ok`.
synchronous :: proc(db: ^Conn) -> (level: Synchronous, rc: Result) {
    assert(db != nil, "synchronous needs a connection")

    stmt: ^Stmt
    stmt, rc = prepare(db, "PRAGMA synchronous")

    if rc != .Ok do return .Off, rc
    defer finalize(stmt)
    assert(column_count(stmt) == 1, "PRAGMA synchronous reports one column")

    rc = step(stmt)

    if is_error(rc) do return .Off, rc

    assert(rc == .Row, "PRAGMA synchronous always reports a row")

    // SQLite reporting its own setting, never file or peer data: off-scale is a
    // broken library, not bad input.
    raw := column_i64(stmt, 0)
    assert(raw >= i64(Synchronous.Off), "PRAGMA synchronous reports a level SQLite defines")
    assert(raw <= i64(Synchronous.Extra), "PRAGMA synchronous reports a level SQLite defines")

    return Synchronous(raw), .Ok
}

// Run zero or more SQL statements with no bind parameters. Rows a statement produces
// are stepped through and discarded.
exec :: proc(db: ^Conn, sql: string) -> Result {
    assert(db != nil, "exec needs a connection")

    if len(sql) > bits.I32_MAX do return .Too_Big

    rest := sql
    for len(rest) > 0 {
        st: ^Stmt
        tail: cstring
        rc := c_prepare_v2(db, cstring(raw_data(rest)), c.int(len(rest)), &st, &tail)

        if rc != .Ok do return rc

        // A statement that compiles always advances the tail, so the loop cannot spin.
        consumed := int(uintptr(rawptr(tail)) - uintptr(rawptr(raw_data(rest))))
        assert(consumed > 0, "prepare consumed no input")
        assert(consumed <= len(rest), "prepare read past the statement buffer")

        // Trailing whitespace or a comment compiles to no statement at all.
        if st != nil {
            rc = step(st)
            for rc == .Row {
                rc = step(st)
            }

            fin := finalize(st)

            if is_error(rc) do return rc

            if fin != .Ok do return fin
        }

        rest = rest[consumed:]
    }

    return .Ok
}

// Open a transaction. SQLite has no nested transactions and answers `.Error` when
// one is already open, which is also how a failed ROLLBACK surfaces.
txn_begin :: proc(db: ^Conn, behavior: Transaction_Behavior) -> Result {
    assert(db != nil, "txn_begin needs a connection")

    rc := exec(db, txn_begin_sql[behavior])

    if rc != .Ok do return rc

    assert(!autocommit(db), "a successful BEGIN starts a transaction")
    return .Ok
}

// Commit the active transaction. A failed COMMIT may or may not have rolled back
// on its own, so an error path wants `txn_rollback` either way.
txn_commit :: proc(db: ^Conn) -> Result {
    assert(db != nil, "txn_commit needs a connection")
    assert(!autocommit(db), "COMMIT requires an active transaction")

    rc := exec(db, "COMMIT")

    if rc != .Ok do return rc

    assert(autocommit(db), "a successful COMMIT ends the transaction")
    return .Ok
}

// Roll back the active transaction, if any. Idempotent, so an error path runs it
// without knowing whether a failed COMMIT already ended the transaction.
txn_rollback :: proc(db: ^Conn) -> Result {
    assert(db != nil, "txn_rollback needs a connection")

    if autocommit(db) do return .Ok

    rc := exec(db, "ROLLBACK")

    if rc != .Ok do return rc

    assert(autocommit(db), "a successful ROLLBACK ends the transaction")
    return .Ok
}

// Prepare a single statement. Caller must `finalize` it.
@(require_results)
prepare :: proc(db: ^Conn, sql: string) -> (stmt: ^Stmt, rc: Result) {
    assert(db != nil, "prepare needs a connection")
    assert(len(sql) > 0, "prepare needs non-empty sql")

    if len(sql) > bits.I32_MAX do return nil, .Too_Big

    // SQLite accepts a counted, non-NUL-terminated buffer when nByte is exact.
    rc = c_prepare_v2(db, cstring(raw_data(sql)), c.int(len(sql)), &stmt, nil)

    if rc != .Ok do stmt = nil

    return
}

// Destroy a prepared statement and return its most recent evaluation result.
// A nil statement is a no-op returning `.Ok`.
finalize :: proc(stmt: ^Stmt) -> Result {
    return c_finalize(stmt)
}

// Reset a statement for re-execution without clearing its bindings.
reset :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "reset needs a statement")

    return c_reset(stmt)
}

// Reset every bound parameter to SQL NULL.
clear_bindings :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "clear_bindings needs a statement")

    return c_clear_bindings(stmt)
}

// Advance a statement, returning `.Row`, `.Done`, or an error result.
@(require_results)
step :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "step needs a statement")

    return c_step(stmt)
}

// Advance a row-reading loop: `.Row` yields a row, `.Done` ends it, and any error
// propagates through `rc`. Callers loop `for { if !step_row(st) or_return { break } }`.
@(require_results)
step_row :: proc(stmt: ^Stmt) -> (has_row: bool, rc: Result) {
    assert(stmt != nil, "step_row needs a statement")

    result := step(stmt)
    if result == .Row do return true, .Ok
    if is_error(result) do return false, result

    assert(result == .Done, "step_row either yields a row or completes")

    return false, .Ok
}

// Reset a statement and release its parameter memory. Both calls always run, and
// the result is `reset`'s, which reports the preceding step's failure.
reset_and_clear :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "reset_and_clear needs a statement")

    rc := reset(stmt)
    cleared := clear_bindings(stmt)

    return rc if rc != .Ok else cleared
}

// Step a bound statement that yields no rows and leave it clean for reuse. Resets
// whether or not the step succeeded; `.Row` means the statement wanted `step`.
execute_stmt :: proc(stmt: ^Stmt) -> Result {
    assert(stmt != nil, "execute needs a statement")

    stepped := step(stmt)
    finished := reset_and_clear(stmt)

    if stepped != .Done do return stepped

    return finished
}

// Read exactly one row of one integer column. `.Done` is no row, `.Row` a second
// one, `.Mismatch` another storage class.
@(require_results)
query_one_i64 :: proc(db: ^Conn, sql: string) -> (value: i64, rc: Result) {
    assert(db != nil, "query_one_i64 needs a connection")
    assert(len(sql) > 0, "query_one_i64 needs a statement")

    st: ^Stmt
    st, rc = prepare(db, sql)

    if rc != .Ok do return 0, rc
    defer finalize(st)
    assert(column_count(st) == 1, "query_one_i64 sql returns one column")

    rc = step(st)

    if rc != .Row do return 0, rc

    if column_type(st, 0) != .Integer do return 0, .Mismatch

    value = column_i64(st, 0)
    rc = step(st)

    if rc != .Done do return 0, rc

    return value, .Ok
}

// Like `query_one_i64` for one text column, cloned into `allocator` because the
// column borrow dies with the statement. `.No_Mem` if the clone fails.
@(require_results)
query_one_text :: proc(db: ^Conn, sql: string, allocator := context.allocator) -> (value: string, rc: Result) {
    assert(db != nil, "query_one_text needs a connection")
    assert(len(sql) > 0, "query_one_text needs a statement")

    st: ^Stmt
    st, rc = prepare(db, sql)

    if rc != .Ok do return "", rc
    defer finalize(st)
    assert(column_count(st) == 1, "query_one_text sql returns one column")

    rc = step(st)

    if rc != .Row do return "", rc

    if column_type(st, 0) != .Text do return "", .Mismatch

    borrowed, column_rc := column_text(st, 0)
    if column_rc != .Ok do return "", column_rc

    cloned, clone_err := strings.clone(borrowed, allocator)
    if clone_err != nil do return "", .No_Mem

    rc = step(st)

    if rc != .Done {
        delete(cloned, allocator)
        return "", rc
    }

    return cloned, .Ok
}

// Compare exactly one row of one text column while its statement keeps the
// column borrow alive. This is the allocation-free predicate form of
// `query_one_text`.
@(require_results)
query_one_text_equal :: proc(db: ^Conn, sql: string, expected: string) -> (equal: bool, rc: Result) {
    assert(db != nil, "query_one_text_equal needs a connection")
    assert(len(sql) > 0, "query_one_text_equal needs a statement")

    st: ^Stmt
    st, rc = prepare(db, sql)

    if rc != .Ok do return false, rc
    defer finalize(st)
    assert(column_count(st) == 1, "query_one_text_equal sql returns one column")

    rc = step(st)

    if rc != .Row do return false, rc

    if column_type(st, 0) != .Text do return false, .Mismatch

    value, column_rc := column_text(st, 0)
    if column_rc != .Ok do return false, column_rc

    equal = value == expected
    rc = step(st)

    if rc != .Done do return false, rc

    return equal, .Ok
}

// Bind a 1-based parameter as i64.
@(require_results)
bind_i64 :: proc(stmt: ^Stmt, index: int, value: i64) -> Result {
    assert(stmt != nil, "bind_i64 needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX do return .Range

    return c_bind_int64(stmt, c.int(index), value)
}

// Bind a 1-based parameter as f64.
@(require_results)
bind_f64 :: proc(stmt: ^Stmt, index: int, value: f64) -> Result {
    assert(stmt != nil, "bind_f64 needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX do return .Range

    return c_bind_double(stmt, c.int(index), value)
}

// Bind a 1-based parameter as UTF-8 text. Uses TRANSIENT so SQLite copies
// immediately; the Odin string need not outlive the call.
@(require_results)
bind_text :: proc(stmt: ^Stmt, index: int, value: string) -> Result {
    return bind_text_lifetime(stmt, index, value, .Transient)
}

@(private)
bind_text_lifetime :: proc(stmt: ^Stmt, index: int, value: string, lifetime: Bind_Lifetime) -> Result {
    assert(stmt != nil, "bind_text needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX do return .Range

    if len(value) > bits.I32_MAX do return .Too_Big

    destructor := TRANSIENT

    if lifetime == .Statement do destructor = STATIC

    data := cstring("")

    if len(value) > 0 do data = cstring(raw_data(value))

    return c_bind_text(stmt, c.int(index), data, c.int(len(value)), destructor)
}

// Bind a 1-based parameter as a blob. Uses TRANSIENT so SQLite copies.
@(require_results)
bind_blob :: proc(stmt: ^Stmt, index: int, value: []byte) -> Result {
    return bind_blob_lifetime(stmt, index, value, .Transient)
}

@(private)
bind_blob_lifetime :: proc(stmt: ^Stmt, index: int, value: []byte, lifetime: Bind_Lifetime) -> Result {
    assert(stmt != nil, "bind_blob needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX do return .Range

    if len(value) > bits.I32_MAX do return .Too_Big

    destructor := TRANSIENT

    if lifetime == .Statement do destructor = STATIC

    data := rawptr(&empty_blob_sentinel)

    if len(value) > 0 do data = raw_data(value)

    return c_bind_blob(stmt, c.int(index), data, c.int(len(value)), destructor)
}

// Bind a 1-based parameter as SQL NULL.
@(require_results)
bind_null :: proc(stmt: ^Stmt, index: int) -> Result {
    assert(stmt != nil, "bind_null needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    if index > bits.I32_MAX do return .Range

    return c_bind_null(stmt, c.int(index))
}

// Largest parameter index in a statement. With `?NNN` markers the indices may
// have gaps, so this is a bound rather than a count of distinct parameters.
bind_parameter_count :: proc(stmt: ^Stmt) -> int {
    assert(stmt != nil, "bind_parameter_count needs a statement")

    return int(c_bind_parameter_count(stmt))
}

// Name of a 1-based parameter with its prefix character included (":seq"), or ""
// for a nameless `?`. Borrowed from the statement and dead once it is finalized.
bind_parameter_name :: proc(stmt: ^Stmt, index: int) -> string {
    assert(stmt != nil, "bind_parameter_name needs a statement")
    assert(index >= 1, "bind parameter index is 1-based")

    name := c_bind_parameter_name(stmt, c.int(index))

    return "" if name == nil else string(name)
}

// Index of a named parameter, or 0 when the statement has none. `name` carries
// its prefix character, exactly as `bind_parameter_name` reports it.
bind_parameter_index :: proc(stmt: ^Stmt, name: cstring) -> int {
    assert(stmt != nil, "bind_parameter_index needs a statement")

    return int(c_bind_parameter_index(stmt, name))
}

// Return the number of columns in the prepared statement's result set.
column_count :: proc(stmt: ^Stmt) -> int {
    assert(stmt != nil, "column_count needs a statement")
    return int(c_column_count(stmt))
}

// Name of a 0-based result column. Borrowed, and shorter-lived than
// `column_text`: SQLite may free it at `finalize`, at the automatic re-prepare on
// the next `step`, or at the next `column_name` call for this same column.
// Compare or clone it before any of those. Unaliased expressions have no defined
// name, so only plain column references are meaningfully identified this way.
column_name :: proc(stmt: ^Stmt, col: int) -> string {
    assert(stmt != nil, "column_name needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")

    name := c_column_name(stmt, c.int(col))

    if name == nil do return ""

    return string(name)
}

// The declared type of a 0-based result column, exactly as written in its
// `CREATE TABLE`, or "" if the column is an expression rather than a plain table
// reference — SQLite reports no declared type for those. Callable at prepare time;
// unlike `column_type`, this needs no current row.
column_decltype :: proc(stmt: ^Stmt, col: int) -> string {
    assert(stmt != nil, "column_decltype needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")

    decl := c_column_decltype(stmt, c.int(col))

    if decl == nil do return ""

    return string(decl)
}

// Return the SQLite storage class of the current row's 0-based column.
column_type :: proc(stmt: ^Stmt, col: int) -> Type {
    assert(stmt != nil, "column_type needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")
    assert(c_stmt_busy(stmt) != 0, "column access needs a current row")

    return c_column_type(stmt, c.int(col))
}

// Read the current row's 0-based column as i64 using SQLite conversion rules.
column_i64 :: proc(stmt: ^Stmt, col: int) -> i64 {
    assert(stmt != nil, "column_i64 needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")
    assert(c_stmt_busy(stmt) != 0, "column access needs a current row")

    return c_column_int64(stmt, c.int(col))
}

// Read the current row's 0-based column as f64 using SQLite conversion rules.
column_f64 :: proc(stmt: ^Stmt, col: int) -> f64 {
    assert(stmt != nil, "column_f64 needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")
    assert(c_stmt_busy(stmt) != 0, "column access needs a current row")

    return c_column_double(stmt, c.int(col))
}

// Borrow the column as an Odin string view. Valid until the next call that
// invalidates the statement's row (step/reset/finalize) or re-reads columns. A
// non-NULL value that SQLite cannot convert because of OOM returns `.No_Mem`.
@(require_results)
column_text :: proc(stmt: ^Stmt, col: int) -> (value: string, rc: Result) {
    assert(stmt != nil, "column_text needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")
    assert(c_stmt_busy(stmt) != 0, "column access needs a current row")

    storage := c_column_type(stmt, c.int(col))
    text := c_column_text(stmt, c.int(col))
    if text == nil do return "", .Ok if storage == .Null else .No_Mem

    n := int(c_column_bytes(stmt, c.int(col)))
    if n <= 0 do return "", .Ok

    return string((cast([^]byte)rawptr(text))[:n]), .Ok
}

// Borrow the column as a byte slice. Same lifetime rules as column_text.
column_blob :: proc(stmt: ^Stmt, col: int) -> []byte {
    assert(stmt != nil, "column_blob needs a statement")
    assert(col >= 0, "column index is 0-based")
    assert(col < column_count(stmt), "column index is in range")
    assert(c_stmt_busy(stmt) != 0, "column access needs a current row")

    p := c_column_blob(stmt, c.int(col))

    n := int(c_column_bytes(stmt, c.int(col)))
    if n <= 0 do return nil

    if p == nil do return nil

    return (cast([^]byte)p)[:n]
}

// English error message for the most recent failure on `db`. Empty if none.
// Borrowed until the next SQLite call on this connection.
errmsg :: proc(db: ^Conn) -> string {
    if db == nil do return ""

    msg := c_errmsg(db)
    if msg == nil do return ""

    return string(msg)
}

// Return the primary result code for the connection's most recent failure.
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

// Return the rows changed by the connection's most recent write statement.
changes :: proc(db: ^Conn) -> int {
    assert(db != nil, "changes needs a connection")

    return int(c_changes(db))
}

// Return the rowid from the connection's most recent successful INSERT.
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

    if nlog != nil do nlog^ = int(cnlog)

    if nckpt != nil do nckpt^ = int(cnckpt)

    return rc
}
