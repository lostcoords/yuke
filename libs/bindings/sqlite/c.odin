package sqlite

import "core:c"

// Opaque connection handle (`sqlite3 *`).
Conn :: struct {}

// Opaque prepared statement (`sqlite3_stmt *`).
Stmt :: struct {}

// Result codes from the C API. `.Ok`, `.Row`, and `.Done` are the normal
// non-error outcomes of open/prepare/step; everything else is a failure.
Result :: enum c.int {
    Ok         = 0,
    Error      = 1,
    Internal   = 2,
    Perm       = 3,
    Abort      = 4,
    Busy       = 5,
    Locked     = 6,
    No_Mem     = 7,
    Read_Only  = 8,
    Interrupt  = 9,
    Io_Err     = 10,
    Corrupt    = 11,
    Not_Found  = 12,
    Full       = 13,
    Cant_Open  = 14,
    Protocol   = 15,
    Empty      = 16,
    Schema     = 17,
    Too_Big    = 18,
    Constraint = 19,
    Mismatch   = 20,
    Misuse     = 21,
    No_Lfs     = 22,
    Auth       = 23,
    Format     = 24,
    Range      = 25,
    Not_A_Db   = 26,
    Notice     = 27,
    Warning    = 28,
    Row        = 100,
    Done       = 101,
}

// Storage class of a column value from `column_type`.
Type :: enum c.int {
    Integer = 1,
    Float   = 2,
    Text    = 3,
    Blob    = 4,
    Null    = 5,
}

// Private C FFI. Importers of `libs:bindings/sqlite` cannot see these symbols.
// Public wrappers in sqlite.odin own the Odin-facing names (bind_text, close, …).

@(private)
Destructor :: distinct rawptr

@(private)
STATIC :: Destructor(uintptr(0))

@(private)
TRANSIENT :: Destructor(~uintptr(0))

// foreign import itself cannot be @(private); the c_* decls below are.
when ODIN_OS == .Windows {
    // Built from amalgamation via `make deps` → libs/bindings/sqlite/bin/.
    foreign import lib "bin/sqlite3.lib"
} else {
    foreign import lib "system:sqlite3"
}

@(private, default_calling_convention = "c")
foreign lib {
    @(link_name = "sqlite3_libversion")
    c_libversion :: proc() -> cstring ---
    @(link_name = "sqlite3_libversion_number")
    c_libversion_number :: proc() -> c.int ---
    @(link_name = "sqlite3_sourceid")
    c_sourceid :: proc() -> cstring ---

    @(link_name = "sqlite3_open_v2")
    c_open_v2 :: proc(filename: cstring, ppDb: ^^Conn, flags: c.int, zVfs: cstring) -> Result ---
    @(link_name = "sqlite3_close")
    c_close :: proc(db: ^Conn) -> Result ---
    @(link_name = "sqlite3_close_v2")
    c_close_v2 :: proc(db: ^Conn) -> Result ---

    @(link_name = "sqlite3_exec")
    c_exec :: proc(db: ^Conn, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> Result ---

    @(link_name = "sqlite3_prepare_v2")
    c_prepare_v2 :: proc(db: ^Conn, zSql: cstring, nByte: c.int, ppStmt: ^^Stmt, pzTail: ^cstring) -> Result ---

    @(link_name = "sqlite3_step")
    c_step :: proc(stmt: ^Stmt) -> Result ---
    @(link_name = "sqlite3_stmt_busy")
    c_stmt_busy :: proc(stmt: ^Stmt) -> c.int ---
    @(link_name = "sqlite3_reset")
    c_reset :: proc(stmt: ^Stmt) -> Result ---
    @(link_name = "sqlite3_finalize")
    c_finalize :: proc(stmt: ^Stmt) -> Result ---
    @(link_name = "sqlite3_clear_bindings")
    c_clear_bindings :: proc(stmt: ^Stmt) -> Result ---

    @(link_name = "sqlite3_bind_int64")
    c_bind_int64 :: proc(stmt: ^Stmt, index: c.int, value: i64) -> Result ---
    @(link_name = "sqlite3_bind_double")
    c_bind_double :: proc(stmt: ^Stmt, index: c.int, value: f64) -> Result ---
    @(link_name = "sqlite3_bind_text")
    c_bind_text :: proc(stmt: ^Stmt, index: c.int, value: cstring, n: c.int, destructor: Destructor) -> Result ---
    @(link_name = "sqlite3_bind_blob")
    c_bind_blob :: proc(stmt: ^Stmt, index: c.int, value: rawptr, n: c.int, destructor: Destructor) -> Result ---
    @(link_name = "sqlite3_bind_null")
    c_bind_null :: proc(stmt: ^Stmt, index: c.int) -> Result ---

    @(link_name = "sqlite3_bind_parameter_count")
    c_bind_parameter_count :: proc(stmt: ^Stmt) -> c.int ---
    @(link_name = "sqlite3_bind_parameter_name")
    c_bind_parameter_name :: proc(stmt: ^Stmt, index: c.int) -> cstring ---
    @(link_name = "sqlite3_bind_parameter_index")
    c_bind_parameter_index :: proc(stmt: ^Stmt, zName: cstring) -> c.int ---

    @(link_name = "sqlite3_column_count")
    c_column_count :: proc(stmt: ^Stmt) -> c.int ---
    @(link_name = "sqlite3_column_name")
    c_column_name :: proc(stmt: ^Stmt, iCol: c.int) -> cstring ---
    @(link_name = "sqlite3_column_type")
    c_column_type :: proc(stmt: ^Stmt, iCol: c.int) -> Type ---
    @(link_name = "sqlite3_column_int64")
    c_column_int64 :: proc(stmt: ^Stmt, iCol: c.int) -> i64 ---
    @(link_name = "sqlite3_column_double")
    c_column_double :: proc(stmt: ^Stmt, iCol: c.int) -> f64 ---
    @(link_name = "sqlite3_column_text")
    c_column_text :: proc(stmt: ^Stmt, iCol: c.int) -> cstring ---
    @(link_name = "sqlite3_column_blob")
    c_column_blob :: proc(stmt: ^Stmt, iCol: c.int) -> rawptr ---
    @(link_name = "sqlite3_column_bytes")
    c_column_bytes :: proc(stmt: ^Stmt, iCol: c.int) -> c.int ---

    @(link_name = "sqlite3_errmsg")
    c_errmsg :: proc(db: ^Conn) -> cstring ---
    @(link_name = "sqlite3_errcode")
    c_errcode :: proc(db: ^Conn) -> Result ---
    @(link_name = "sqlite3_extended_errcode")
    c_extended_errcode :: proc(db: ^Conn) -> c.int ---

    @(link_name = "sqlite3_busy_timeout")
    c_busy_timeout :: proc(db: ^Conn, ms: c.int) -> Result ---
    @(link_name = "sqlite3_changes")
    c_changes :: proc(db: ^Conn) -> c.int ---
    @(link_name = "sqlite3_last_insert_rowid")
    c_last_insert_rowid :: proc(db: ^Conn) -> i64 ---
    @(link_name = "sqlite3_get_autocommit")
    c_get_autocommit :: proc(db: ^Conn) -> c.int ---

    @(link_name = "sqlite3_wal_checkpoint_v2")
    c_wal_checkpoint_v2 :: proc(db: ^Conn, zDb: cstring, eMode: c.int, pnLog: ^c.int, pnCkpt: ^c.int) -> Result ---

    @(link_name = "sqlite3_free")
    c_free :: proc(p: rawptr) ---
}
