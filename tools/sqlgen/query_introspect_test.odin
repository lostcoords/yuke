package sqlgen

import "core:testing"

import "libs:bindings/sqlite"
import "tools:gen"

@(test)
test_query_resolve_uses_annotation_type_for_params_and_row :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (a INTEGER NOT NULL, b TEXT)"), sqlite.Result.Ok)

    defs, parse_ok := parse_queries(
        "-- name: Get :one\n-- id: wire.Widget_Id!\n-- a: wire.Count!\nSELECT a, b FROM t WHERE a = :id;\n",
    )
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    resolved, ok := query_resolve(db, defs[0], &d)
    defer resolved_query_destroy(resolved)
    testing.expect(t, ok)
    testing.expect(t, !gen.diags_failed(&d))

    testing.expect_value(t, len(resolved.params), 1)
    testing.expect_value(t, resolved.params[0].name, "id")
    testing.expect_value(t, resolved.params[0].odin_type, "wire.Widget_Id")
    testing.expect(t, resolved.params[0].required)

    testing.expect_value(t, len(resolved.row), 2)
    testing.expect_value(t, resolved.row[0].name, "a")
    testing.expect_value(t, resolved.row[0].odin_type, "wire.Count")
    testing.expect(t, resolved.row[0].required)
    testing.expect_value(t, resolved.row[1].name, "b")
    testing.expect_value(t, resolved.row[1].odin_type, "string")
    testing.expect(t, !resolved.row[1].required, "an unannotated column defaults to optional")
}

@(test)
test_query_resolve_falls_back_to_decltype_for_a_plain_column :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (b REAL, c BLOB)"), sqlite.Result.Ok)

    defs, parse_ok := parse_queries("-- name: Get :many\nSELECT b, c FROM t;\n")
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    resolved, ok := query_resolve(db, defs[0], &d)
    defer resolved_query_destroy(resolved)
    testing.expect(t, ok)
    testing.expect_value(t, resolved.row[0].odin_type, "f64")
    testing.expect_value(t, resolved.row[1].odin_type, "[]byte")
}

@(test)
test_query_resolve_requires_an_annotation_for_an_integer_column :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (n INTEGER NOT NULL)"), sqlite.Result.Ok)

    defs, parse_ok := parse_queries("-- name: Get :many\nSELECT n FROM t;\n")
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := query_resolve(db, defs[0], &d)
    testing.expect(t, !ok, "an unannotated INTEGER result column cannot be silently typed u64")
    testing.expect(t, gen.diags_failed(&d))
}

@(test)
test_query_resolve_requires_a_param_annotation :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (a INTEGER)"), sqlite.Result.Ok)

    defs, parse_ok := parse_queries("-- name: Get :exec\nDELETE FROM t WHERE a = :a;\n")
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := query_resolve(db, defs[0], &d)
    testing.expect(t, !ok, "a bind parameter has no type SQLite can report; annotation is mandatory")
    testing.expect(t, gen.diags_failed(&d))
}

@(test)
test_query_resolve_requires_annotation_for_a_computed_column :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (a INTEGER)"), sqlite.Result.Ok)

    defs, parse_ok := parse_queries("-- name: Get :one\nSELECT count(*) AS total FROM t;\n")
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := query_resolve(db, defs[0], &d)
    testing.expect(t, !ok, "decltype is empty for an aggregate; annotation is mandatory")
    testing.expect(t, gen.diags_failed(&d))
}

@(test)
test_query_resolve_reports_sql_that_does_not_prepare :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    defs, parse_ok := parse_queries("-- name: Bad :exec\nNOT VALID SQL;\n")
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := query_resolve(db, defs[0], &d)
    testing.expect(t, !ok)
    testing.expect(t, gen.diags_failed(&d))
}

@(test)
test_query_resolve_skips_the_row_for_an_unnamed_column :: proc(t: ^testing.T) {
    db, rc := sqlite.open_memory()
    testing.expect_value(t, rc, sqlite.Result.Ok)
    defer testing.expect_value(t, sqlite.close(db), sqlite.Result.Ok)

    testing.expect_value(t, sqlite.exec(db, "CREATE TABLE t (a INTEGER)"), sqlite.Result.Ok)

    defs, parse_ok := parse_queries("-- name: Exists :manual\nSELECT 1 FROM t;\n")
    testing.expect(t, parse_ok)
    defer query_defs_destroy(defs)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    resolved, ok := query_resolve(db, defs[0], &d)
    defer resolved_query_destroy(resolved)
    testing.expect(t, ok)
    testing.expect_value(t, len(resolved.row), 0)
}
