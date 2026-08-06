package sqlite

import "core:testing"

// `read_all`/`read_one` both advance or reset the statement past a row before
// returning it, so a `borrowed` destination field would hand the caller a
// dangling pointer. `reader_prepare` refuses the shape rather than allow it.
@(test)
test_reader_prepare_rejects_a_borrowed_scan_field :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 'x' AS a")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        a: string `sql:",borrowed"`,
    }

    _, err := reader_prepare(st, struct {}, Row)
    testing.expect_value(t, err, Scan_Error.Invalid_Tag)
}

@(test)
test_read_all_collects_every_row :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a TEXT, b INTEGER)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t VALUES ('x', 1), ('y', 2), ('z', 3)"), Result.Ok)

    st, prep := prepare(db, "SELECT a, b FROM t WHERE b >= :min ORDER BY b")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Params :: struct {
        min: i64,
    }
    Row :: struct {
        a: string,
        b: i64,
    }

    reader, reader_err := reader_prepare(st, Params, Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    rows, err := read_all(&reader, &Params{min = 2}, context.allocator)
    defer delete(rows)
    defer for &row in rows {
        scan_destroy(&row)
    }
    testing.expect_value(t, err, Error(nil))
    testing.expect_value(t, len(rows), 2)
    testing.expect_value(t, rows[0].a, "y")
    testing.expect_value(t, rows[1].b, i64(3))
}

@(test)
test_read_all_on_an_empty_result_returns_an_empty_slice :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER)"), Result.Ok)

    st, prep := prepare(db, "SELECT a FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        a: i64,
    }

    reader, reader_err := reader_prepare(st, struct {}, Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    rows, err := read_all(&reader, &struct{}{}, context.allocator)
    defer delete(rows)
    testing.expect_value(t, err, Error(nil))
    testing.expect_value(t, len(rows), 0)
}

@(test)
test_read_one_returns_the_single_row :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t VALUES (7)"), Result.Ok)

    st, prep := prepare(db, "SELECT a FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        a: i64,
    }

    reader, reader_err := reader_prepare(st, struct {}, Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    row, err := read_one(&reader, &struct{}{}, context.allocator)
    testing.expect_value(t, err, Error(nil))
    testing.expect_value(t, row.a, i64(7))
}

@(test)
test_read_one_rejects_a_wrong_row_count :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER)"), Result.Ok)

    st, prep := prepare(db, "SELECT a FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        a: i64,
    }

    reader, reader_err := reader_prepare(st, struct {}, Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    _, zero_err := read_one(&reader, &struct{}{}, context.allocator)
    testing.expect_value(t, zero_err, Error(Read_Error.Row_Count))

    testing.expect_value(t, exec(db, "INSERT INTO t VALUES (1), (2)"), Result.Ok)

    _, many_err := read_one(&reader, &struct{}{}, context.allocator)
    testing.expect_value(t, many_err, Error(Read_Error.Row_Count))
}

// A row `read_one` already scanned and cloned must not leak when a second row
// turns up and the call rejects the whole result as a row-count failure.
@(test)
test_read_one_releases_the_scanned_row_on_a_rejected_count :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a TEXT)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t VALUES ('one'), ('two')"), Result.Ok)

    st, prep := prepare(db, "SELECT a FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        a: string,
    }

    reader, reader_err := reader_prepare(st, struct {}, Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    _, err := read_one(&reader, &struct{}{}, context.allocator)
    testing.expect_value(t, err, Error(Read_Error.Row_Count))
}

// Rows already collected before a mid-loop scan failure must not leak, nor must
// the collection's own backing storage.
@(test)
test_read_all_releases_prior_rows_on_a_mid_loop_scan_failure :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a TEXT)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t VALUES ('one'), (NULL)"), Result.Ok)

    st, prep := prepare(db, "SELECT a FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // Non-nullable `a`: the second row's NULL fails the scan after the first
    // row already cloned its text.
    Row :: struct {
        a: string,
    }

    reader, reader_err := reader_prepare(st, struct {}, Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    rows, err := read_all(&reader, &struct{}{}, context.allocator)
    testing.expect_value(t, err, Error(Scan_Error.Null_Not_Allowed))
    testing.expect_value(t, len(rows), 0)
}
