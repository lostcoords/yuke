package sqlgen

import "core:testing"

import "libs:bindings/sqlite"

@(test)
test_table_columns_reports_pragma_table_info :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (a INTEGER NOT NULL, b TEXT)"), sqlite.Result.Ok)

    columns, ok := table_columns(db, "t")
    defer delete(columns)
    defer for &col in columns {
        sqlite.scan_destroy(&col)
    }
    testing.expect(t, ok, "a real table reports its columns")
    testing.expect_value(t, len(columns), 2)
    testing.expect_value(t, columns[0].name, "a")
    testing.expect_value(t, columns[0].type, "INTEGER")
    testing.expect(t, columns[0].not_null, "a is declared NOT NULL")
    testing.expect_value(t, columns[1].name, "b")
    testing.expect(t, !columns[1].not_null, "b is nullable")
}

@(test)
test_table_columns_rejects_an_unknown_table :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    _, ok := table_columns(db, "nope")
    testing.expect(t, !ok, "a table that was never created reports no columns")
}
