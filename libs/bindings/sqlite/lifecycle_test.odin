package sqlite

import "core:testing"

// One realistic end-to-end pass through the package's whole surface against a
// real `:memory:` connection: insert_all_sql feeding bind_prepare, a Reader
// driving read_all and read_one, a commit and a rollback, NULL round-tripping
// through Maybe, and an optional/borrowed scan field.
@(test)
test_lifecycle_exercises_bind_scan_and_reader_together :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(
        t,
        exec(
            db,
            `CREATE TABLE widgets (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                weight REAL NOT NULL,
                payload BLOB,
                note TEXT NOT NULL
            )`,
        ),
        Result.Ok,
    )

    // insert_all_sql end to end: generate the statement from the struct shape,
    // prepare it, and resolve it with bind_prepare.
    Widget :: struct {
        id:      i64,
        name:    string,
        weight:  f64,
        payload: Maybe([]byte),
        note:    string,
    }

    insert_sql := insert_all_sql("widgets", Widget, context.allocator)
    defer delete(insert_sql, context.allocator)
    testing.expect_value(
        t,
        insert_sql,
        "INSERT INTO widgets (id, name, weight, payload, note) VALUES (:id, :name, :weight, :payload, :note)",
    )

    insert_stmt, insert_prep := prepare(db, insert_sql)
    testing.expect_value(t, insert_prep, Result.Ok)
    defer testing.expect_value(t, finalize(insert_stmt), Result.Ok)

    insert_mapping, insert_mapping_err := bind_prepare(insert_stmt, Widget)
    testing.expect_value(t, insert_mapping_err, Bind_Error.None)

    // A committed transaction: two widgets, one with a blob payload, one with
    // its payload left NULL through the Maybe field.
    testing.expect_value(t, txn_begin(db, .Immediate), Result.Ok)

    with_payload := Widget {
        id      = 1,
        name    = "cog",
        weight  = 1.5,
        payload = []byte{0xde, 0xad, 0xbe, 0xef},
        note    = "spins",
    }
    testing.expect_value(t, execute(&insert_mapping, &with_payload), Result.Ok)

    without_payload := Widget {
        id     = 2,
        name   = "bolt",
        weight = 0.2,
        note   = "threaded",
    }
    testing.expect_value(t, execute(&insert_mapping, &without_payload), Result.Ok)

    testing.expect_value(t, txn_commit(db), Result.Ok)

    // A rolled-back transaction: this row must never be visible afterward.
    testing.expect_value(t, txn_begin(db, .Immediate), Result.Ok)

    doomed := Widget {
        id     = 3,
        name   = "ghost",
        weight = 9.9,
        note   = "unseen",
    }
    testing.expect_value(t, execute(&insert_mapping, &doomed), Result.Ok)
    testing.expect_value(t, txn_rollback(db), Result.Ok)

    // Reader: bind + scan bundled, exercised through both read_all and read_one.
    // `payload` round-trips NULL through Maybe.
    Widget_Row :: struct {
        id:      i64,
        name:    string,
        weight:  f64,
        payload: Maybe([]byte),
        note:    string,
    }

    Empty_Params :: struct {}

    select_stmt, select_prep := prepare(db, "SELECT id, name, weight, payload, note FROM widgets ORDER BY id")
    testing.expect_value(t, select_prep, Result.Ok)
    defer testing.expect_value(t, finalize(select_stmt), Result.Ok)

    reader, reader_err := reader_prepare(select_stmt, Empty_Params, Widget_Row)
    testing.expect_value(t, reader_err, Scan_Error.None)
    defer reader_destroy(&reader)

    rows, read_err := read_all(&reader, &Empty_Params{}, context.allocator)
    testing.expect_value(t, read_err, Error(nil))
    defer delete(rows)
    // `name`, `note`, and `payload`'s set arm are all owned clones.
    defer for &row in rows {
        scan_destroy(&row)
    }

    testing.expect_value(t, len(rows), 2)

    testing.expect_value(t, rows[0].id, i64(1))
    testing.expect_value(t, rows[0].name, "cog")
    testing.expect_value(t, rows[0].note, "spins")
    payload, has_payload := rows[0].payload.?
    testing.expect(t, has_payload, "the first widget carries a payload")
    testing.expect_value(t, len(payload), 4)
    testing.expect_value(t, payload[3], u8(0xef))

    testing.expect_value(t, rows[1].id, i64(2))
    testing.expect_value(t, rows[1].note, "threaded")
    _, second_has_payload := rows[1].payload.?
    testing.expect(t, !second_has_payload, "the second widget's NULL payload scans as the nil variant")

    // `note` is optional here: this SELECT never carries a `note` column, so the
    // field is left at its zero value instead of failing to resolve.
    Id_Row :: struct {
        id:   i64,
        note: string `sql:",optional"`,
    }

    id_stmt, id_prep := prepare(db, "SELECT id FROM widgets ORDER BY id")
    testing.expect_value(t, id_prep, Result.Ok)
    defer testing.expect_value(t, finalize(id_stmt), Result.Ok)

    id_reader, id_reader_err := reader_prepare(id_stmt, Empty_Params, Id_Row)
    testing.expect_value(t, id_reader_err, Scan_Error.None)
    defer reader_destroy(&id_reader)

    id_rows, id_read_err := read_all(&id_reader, &Empty_Params{}, context.allocator)
    testing.expect_value(t, id_read_err, Error(nil))
    defer delete(id_rows)

    testing.expect_value(t, len(id_rows), 2)
    testing.expect_value(t, id_rows[0].note, "")

    // read_one against a statement bound by name, matching the committed count.
    Count_Row :: struct {
        total: i64,
    }

    count_stmt, count_prep := prepare(db, "SELECT count(*) AS total FROM widgets")
    testing.expect_value(t, count_prep, Result.Ok)
    defer testing.expect_value(t, finalize(count_stmt), Result.Ok)

    count_reader, count_reader_err := reader_prepare(count_stmt, Empty_Params, Count_Row)
    testing.expect_value(t, count_reader_err, Scan_Error.None)
    defer reader_destroy(&count_reader)

    total, total_err := read_one(&count_reader, &Empty_Params{}, context.allocator)
    testing.expect_value(t, total_err, Error(nil))
    testing.expect_value(t, total.total, i64(2))
}

// A struct with a field the query never selects is refused at prepare time, not
// silently ignored — the closed mapping invariant `scan_prepare` documents.
@(test)
test_lifecycle_rejects_a_scan_destination_with_an_extra_field :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER)"), Result.Ok)
    testing.expect_value(t, exec(db, "INSERT INTO t VALUES (1)"), Result.Ok)

    st, prep := prepare(db, "SELECT a FROM t")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // `b` has no matching result column.
    Wrong_Shape :: struct {
        a: i64,
        b: i64,
    }

    _, err := scan_prepare(st, Wrong_Shape)
    testing.expect_value(t, err, Scan_Error.Column_Missing)
}
