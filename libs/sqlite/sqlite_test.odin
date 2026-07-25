package sqlite

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_libversion_is_present :: proc(t: ^testing.T) {
    ver := libversion()
    testing.expect(t, len(ver) > 0, "libversion should be non-empty")
    testing.expect(t, libversion_number() >= 3008000, "need SQLite 3.8+ for WAL baseline")
}

@(test)
test_memory_round_trip :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    testing.expect(t, db != nil, "open_memory returned nil db")
    defer close(db)

    testing.expect_value(t, busy_timeout(db, 1000), Result.Ok)

    rc = exec(
        db,
        `
        CREATE TABLE events (
            session_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY (session_id, seq)
        );
    `,
    )
    testing.expect_value(t, rc, Result.Ok)

    stmt, prep := prepare(db, "INSERT INTO events(session_id, seq, payload) VALUES(?1, ?2, ?3)")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    testing.expect_value(t, bind_text(stmt, 1, "sess-a"), Result.Ok)
    testing.expect_value(t, bind_i64(stmt, 2, 1), Result.Ok)
    testing.expect_value(t, bind_text(stmt, 3, `{"type":"hello"}`), Result.Ok)
    testing.expect_value(t, step(stmt), Result.Done)
    testing.expect_value(t, changes(db), 1)

    q, qrc := prepare(db, "SELECT session_id, seq, payload FROM events WHERE session_id = ?1")
    testing.expect_value(t, qrc, Result.Ok)
    defer finalize(q)

    testing.expect_value(t, bind_text(q, 1, "sess-a"), Result.Ok)
    testing.expect_value(t, step(q), Result.Row)
    testing.expect_value(t, column_text(q, 0), "sess-a")
    testing.expect_value(t, column_i64(q, 1), i64(1))
    testing.expect_value(t, column_text(q, 2), `{"type":"hello"}`)
    testing.expect_value(t, column_type(q, 2), Type.Text)
    testing.expect_value(t, step(q), Result.Done)
}

@(test)
test_blob_and_null_bind :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer close(db)

    testing.expect_value(t, exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB, n TEXT)"), Result.Ok)

    stmt, prep := prepare(db, "INSERT INTO t(id, b, n) VALUES(1, ?1, ?2)")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    blob := []byte{0x00, 0x01, 0xfe, 0xff}
    testing.expect_value(t, bind_blob(stmt, 1, blob), Result.Ok)
    testing.expect_value(t, bind_null(stmt, 2), Result.Ok)
    testing.expect_value(t, step(stmt), Result.Done)

    q, qrc := prepare(db, "SELECT b, n FROM t WHERE id = 1")
    testing.expect_value(t, qrc, Result.Ok)
    defer finalize(q)

    testing.expect_value(t, step(q), Result.Row)
    got := column_blob(q, 0)
    testing.expect_value(t, len(got), len(blob))
    for i in 0 ..< len(blob) {
        testing.expect_value(t, got[i], blob[i])
    }
    testing.expect_value(t, column_type(q, 1), Type.Null)
}

@(test)
test_prepare_error_message :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer close(db)

    stmt, prep := prepare(db, "SELECT * FROM definitely_missing")
    testing.expect(t, is_error(prep), "bad SQL should error")
    testing.expect(t, stmt == nil, "failed prepare must not return a stmt")
    testing.expect(t, len(errmsg(db)) > 0, "errmsg should explain the fault")
}

@(test)
test_file_wal_pragma :: proc(t: ^testing.T) {
    dir, dir_err := os.temp_directory(context.temp_allocator)
    testing.expect(t, dir_err == nil, "temp_directory failed")

    path, join_err := filepath.join({dir, "yuke-sqlite-wal-test.db"}, context.temp_allocator)
    testing.expect_value(t, join_err, mem.Allocator_Error.None)
    wal_path := fmt.tprintf("%s-wal", path)
    shm_path := fmt.tprintf("%s-shm", path)
    defer os.remove(path)
    defer os.remove(wal_path)
    defer os.remove(shm_path)

    db, rc := open(path, DEFAULT_WRITER | {.Nomutex})
    testing.expect_value(t, rc, Result.Ok)
    defer close(db)

    testing.expect_value(t, exec(db, "PRAGMA journal_mode=WAL"), Result.Ok)
    testing.expect_value(t, exec(db, "PRAGMA synchronous=NORMAL"), Result.Ok)

    stmt, prep := prepare(db, "PRAGMA journal_mode")
    testing.expect_value(t, prep, Result.Ok)
    defer finalize(stmt)

    testing.expect_value(t, step(stmt), Result.Row)
    testing.expect_value(t, column_text(stmt, 0), "wal")

    nlog, nckpt: int
    ck := wal_checkpoint(db, .Passive, &nlog, &nckpt)
    testing.expect_value(t, ck, Result.Ok)
}
