package sqlite

import "core:testing"

@(test)
test_bind_matches_parameters_by_name_not_by_order :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a TEXT, b INTEGER, c BLOB)"), Result.Ok)

    st, prep := prepare(db, "INSERT INTO t (a, b, c) VALUES (:a, :b, :c)")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // Declared back to front against the statement's markers; only names bind.
    Params :: struct {
        c: [4]u8,
        b: i64,
        a: string,
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)
    testing.expect_value(t, mapping.count, 3)

    params := Params {
        a = "hello",
        b = 7,
        c = {1, 2, 3, 4},
    }
    testing.expect_value(t, execute(&mapping, &params), Result.Ok)

    sel, sel_prep := prepare(db, "SELECT a, b, c FROM t")
    testing.expect_value(t, sel_prep, Result.Ok)
    defer testing.expect_value(t, finalize(sel), Result.Ok)

    testing.expect_value(t, step(sel), Result.Row)
    text, text_rc := column_text(sel, 0)
    testing.expect_value(t, text_rc, Result.Ok)
    testing.expect_value(t, text, "hello")
    testing.expect_value(t, column_i64(sel, 1), i64(7))
    testing.expect_value(t, len(column_blob(sel, 2)), 4)
    testing.expect_value(t, column_blob(sel, 2)[3], u8(4))
    testing.expect_value(t, step(sel), Result.Done)
}

@(test)
test_bind_prepare_requires_a_closed_one_to_one_shape :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :a, :b")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // A field the statement never asks for.
    Extra :: struct {
        a: i64,
        b: i64,
        c: i64,
    }

    // A parameter no field feeds.
    Partial :: struct {
        a: i64,
    }

    // Two fields racing for one marker.
    Duplicate :: struct {
        a:     i64,
        other: i64 `sql:"a"`,
        b:     i64,
    }

    _, extra_err := bind_prepare(st, Extra)
    testing.expect_value(t, extra_err, Bind_Error.Parameter_Missing)

    _, partial_err := bind_prepare(st, Partial)
    testing.expect_value(t, partial_err, Bind_Error.Field_Missing)

    _, duplicate_err := bind_prepare(st, Duplicate)
    testing.expect_value(t, duplicate_err, Bind_Error.Parameter_Duplicate)
}

// `:a`, `@a`, and `$a` are three distinct parameters that strip to one name. Two
// of them reaching the same field would leave another field silently unbound, so
// the collision is refused rather than resolved.
@(test)
test_bind_prepare_rejects_prefix_aliased_markers :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :a, @a")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // Two markers and two fields: a mapping that counted parameters would call
    // this closed while `b` went unbound and `@a` fed `a` a second time.
    Params :: struct {
        a: i64,
        b: i64,
    }

    testing.expect_value(t, bind_parameter_count(st), 2)

    _, err := bind_prepare(st, Params)
    testing.expect_value(t, err, Bind_Error.Parameter_Duplicate)
}

@(test)
test_bind_prepare_rejects_more_parameters_than_a_mapping_holds :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :a")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // One more field than the slot table holds; the walk must refuse the struct
    // before anything reads the leaf it could not record.
    Wide :: struct {
        f00: i64,
        f01: i64,
        f02: i64,
        f03: i64,
        f04: i64,
        f05: i64,
        f06: i64,
        f07: i64,
        f08: i64,
        f09: i64,
        f10: i64,
        f11: i64,
        f12: i64,
        f13: i64,
        f14: i64,
        f15: i64,
        f16: i64,
        f17: i64,
        f18: i64,
        f19: i64,
        f20: i64,
        f21: i64,
        f22: i64,
        f23: i64,
        f24: i64,
        f25: i64,
        f26: i64,
        f27: i64,
        f28: i64,
        f29: i64,
        f30: i64,
        f31: i64,
        f32: i64,
    }

    #assert(BIND_MAX_PARAMS == 32)

    _, err := bind_prepare(st, Wide)
    testing.expect_value(t, err, Bind_Error.Too_Many_Parameters)
}

@(test)
test_bind_prepare_rejects_ordinal_markers :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    Params :: struct {
        a: i64,
    }

    anonymous, anon_prep := prepare(db, "SELECT ?")
    testing.expect_value(t, anon_prep, Result.Ok)
    defer testing.expect_value(t, finalize(anonymous), Result.Ok)

    numbered, num_prep := prepare(db, "SELECT ?1")
    testing.expect_value(t, num_prep, Result.Ok)
    defer testing.expect_value(t, finalize(numbered), Result.Ok)

    _, anon_err := bind_prepare(anonymous, Params)
    testing.expect_value(t, anon_err, Bind_Error.Parameter_Unnamed)

    _, num_err := bind_prepare(numbered, Params)
    testing.expect_value(t, num_err, Bind_Error.Parameter_Unnamed)
}

// `optional` and `borrowed` describe how a scan takes ownership of SQLite's
// memory. Nothing on the way in can honor them, so they are refused rather than
// quietly ignored.
@(test)
test_bind_prepare_rejects_scan_only_tag_options :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :a")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Optional :: struct {
        a: i64 `sql:",optional"`,
    }

    Borrowed :: struct {
        a: string `sql:",borrowed"`,
    }

    _, optional_err := bind_prepare(st, Optional)
    testing.expect_value(t, optional_err, Bind_Error.Invalid_Tag)

    _, borrowed_err := bind_prepare(st, Borrowed)
    testing.expect_value(t, borrowed_err, Bind_Error.Invalid_Tag)
}

@(test)
test_bind_prepare_rejects_an_unsupported_field_type :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :a")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Nested :: struct {
        x: i64,
    }

    Params :: struct {
        a: Nested,
    }

    _, err := bind_prepare(st, Params)
    testing.expect_value(t, err, Bind_Error.Unsupported_Type)
}

// `sql:"-"` keeps a field out of the mapping entirely, and `using` contributes
// the embedded struct's leaves rather than a marker of its own.
@(test)
test_bind_honors_renames_ignores_and_using :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (hi INTEGER, lo INTEGER)"), Result.Ok)

    st, prep := prepare(db, "INSERT INTO t (hi, lo) VALUES (:hi, :lo)")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Marks :: struct {
        low: i64 `sql:"lo"`,
    }

    Params :: struct {
        high:       i64 `sql:"hi"`,
        using rest: Marks,
        scratch:    string `sql:"-"`,
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)
    testing.expect_value(t, mapping.count, 2)

    params := Params {
        high = 9,
        rest = {low = 4},
        scratch = "never bound",
    }
    testing.expect_value(t, execute(&mapping, &params), Result.Ok)

    sel, sel_prep := prepare(db, "SELECT hi, lo FROM t")
    testing.expect_value(t, sel_prep, Result.Ok)
    defer testing.expect_value(t, finalize(sel), Result.Ok)

    testing.expect_value(t, step(sel), Result.Row)
    testing.expect_value(t, column_i64(sel, 0), i64(9))
    testing.expect_value(t, column_i64(sel, 1), i64(4))
}

// One marker used twice is one parameter, so a struct feeds both occurrences
// from a single field.
@(test)
test_bind_feeds_a_repeated_marker_once :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :n + :n")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Params :: struct {
        n: i64,
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)
    testing.expect_value(t, mapping.count, 1)

    params := Params {
        n = 21,
    }
    testing.expect_value(t, bind(&mapping, &params), Result.Ok)
    testing.expect_value(t, step(st), Result.Row)
    testing.expect_value(t, column_i64(st, 0), i64(42))
}

@(test)
test_bind_carries_every_supported_storage_kind :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :flag, :small, :big, :ratio, :label, :fixed, :loose, :kind")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Kind :: enum u8 {
        Zero = 0,
        Five = 5,
    }

    Params :: struct {
        flag:  bool,
        small: u16,
        big:   u64,
        ratio: f32,
        label: string,
        fixed: [3]u8,
        loose: []byte,
        kind:  Kind,
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)
    testing.expect_value(t, mapping.count, 8)

    blob := []byte{9, 8}
    params := Params {
        flag  = true,
        small = 300,
        big   = 1 << 40,
        ratio = 0.5,
        label = "text",
        fixed = {1, 2, 3},
        loose = blob,
        kind  = .Five,
    }
    testing.expect_value(t, bind(&mapping, &params), Result.Ok)
    testing.expect_value(t, step(st), Result.Row)

    testing.expect_value(t, column_i64(st, 0), i64(1))
    testing.expect_value(t, column_i64(st, 1), i64(300))
    testing.expect_value(t, column_i64(st, 2), i64(1 << 40))
    testing.expect_value(t, column_f64(st, 3), f64(0.5))
    label, label_rc := column_text(st, 4)
    testing.expect_value(t, label_rc, Result.Ok)
    testing.expect_value(t, label, "text")
    testing.expect_value(t, len(column_blob(st, 5)), 3)
    testing.expect_value(t, len(column_blob(st, 6)), 2)
    testing.expect_value(t, column_i64(st, 7), i64(5))
}

// `execute` leaves the statement reset and unbound, so a mapping is reusable
// across appends without carrying a previous row's values.
@(test)
test_execute_bound_leaves_the_statement_reusable :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (n INTEGER NOT NULL)"), Result.Ok)

    st, prep := prepare(db, "INSERT INTO t (n) VALUES (:n)")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Params :: struct {
        n: i64,
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)

    for n in 1 ..= 3 {
        params := Params {
            n = i64(n),
        }
        testing.expect_value(t, execute(&mapping, &params), Result.Ok)
    }

    sel, sel_prep := prepare(db, "SELECT count(*), sum(n) FROM t")
    testing.expect_value(t, sel_prep, Result.Ok)
    defer testing.expect_value(t, finalize(sel), Result.Ok)

    testing.expect_value(t, step(sel), Result.Row)
    testing.expect_value(t, column_i64(sel, 0), i64(3))
    testing.expect_value(t, column_i64(sel, 1), i64(6))
}

@(test)
test_bind_reports_unsigned_values_sqlite_cannot_represent :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :value")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Params :: struct {
        value: u64,
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)

    params := Params {
        value = max(u64),
    }
    testing.expect_value(t, bind(&mapping, &params), Result.Range)
    testing.expect_value(t, reset_and_clear(st), Result.Ok)

    params.value = u64(max(i64))
    testing.expect_value(t, bind(&mapping, &params), Result.Ok)
    testing.expect_value(t, step(st), Result.Row)
    testing.expect_value(t, column_i64(st, 0), max(i64))
}

@(test)
test_bind_maybe_binds_payload_or_null :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER, b TEXT, c BLOB)"), Result.Ok)

    st, prep := prepare(db, "INSERT INTO t (a, b, c) VALUES (:a, :b, :c)")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Params :: struct {
        a: Maybe(u64),
        b: Maybe(string),
        c: Maybe([4]u8),
    }

    mapping, mapping_err := bind_prepare(st, Params)
    testing.expect_value(t, mapping_err, Bind_Error.None)
    testing.expect_value(t, mapping.count, 3)

    present := Params {
        a = 9,
        b = "set",
        c = [4]u8{1, 2, 3, 4},
    }
    testing.expect_value(t, execute(&mapping, &present), Result.Ok)

    absent: Params
    testing.expect_value(t, execute(&mapping, &absent), Result.Ok)

    sel, sel_prep := prepare(db, "SELECT a, b, c FROM t ORDER BY rowid")
    testing.expect_value(t, sel_prep, Result.Ok)
    defer testing.expect_value(t, finalize(sel), Result.Ok)

    testing.expect_value(t, step(sel), Result.Row)
    testing.expect_value(t, column_i64(sel, 0), i64(9))
    text, text_rc := column_text(sel, 1)
    testing.expect_value(t, text_rc, Result.Ok)
    testing.expect_value(t, text, "set")
    testing.expect_value(t, len(column_blob(sel, 2)), 4)

    // The nil arm reaches SQLite as a real NULL, not a zero value.
    testing.expect_value(t, step(sel), Result.Row)
    testing.expect_value(t, column_type(sel, 0), Type.Null)
    testing.expect_value(t, column_type(sel, 1), Type.Null)
    testing.expect_value(t, column_type(sel, 2), Type.Null)
    testing.expect_value(t, step(sel), Result.Done)
}

// The two directions are inverses: whatever a `Maybe` binds, scanning the same row back
// reproduces, nil arm included.
@(test)
test_maybe_round_trips_through_both_directions :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    testing.expect_value(t, exec(db, "CREATE TABLE t (a INTEGER, b TEXT, c BLOB)"), Result.Ok)

    Row :: struct {
        a: Maybe(u64),
        b: Maybe(string),
        c: Maybe([4]u8),
    }

    st, prep := prepare(db, "INSERT INTO t (a, b, c) VALUES (:a, :b, :c)")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    mapping, mapping_err := bind_prepare(st, Row)
    testing.expect_value(t, mapping_err, Bind_Error.None)

    present := Row {
        a = 9,
        b = "set",
        c = [4]u8{1, 2, 3, 4},
    }
    testing.expect_value(t, execute(&mapping, &present), Result.Ok)

    absent: Row
    testing.expect_value(t, execute(&mapping, &absent), Result.Ok)

    sel, sel_prep := prepare(db, "SELECT a, b, c FROM t ORDER BY rowid")
    testing.expect_value(t, sel_prep, Result.Ok)
    defer testing.expect_value(t, finalize(sel), Result.Ok)

    testing.expect_value(t, step(sel), Result.Row)

    set: Row
    testing.expect_value(t, scan_row(sel, &set, context.allocator), Scan_Error.None)
    defer scan_destroy(&set, context.allocator)

    testing.expect_value(t, set.a, present.a)
    testing.expect_value(t, set.b, present.b)
    testing.expect_value(t, set.c, present.c)

    // NULL lands as the nil variant rather than a zero payload wearing a set tag.
    testing.expect_value(t, step(sel), Result.Row)

    nil_row: Row
    testing.expect_value(t, scan_row(sel, &nil_row, context.allocator), Scan_Error.None)
    defer scan_destroy(&nil_row, context.allocator)

    _, a_set := nil_row.a.?
    _, b_set := nil_row.b.?
    _, c_set := nil_row.c.?
    testing.expect(t, !a_set, "a NULL integer scans as the nil variant")
    testing.expect(t, !b_set, "a NULL text scans as the nil variant")
    testing.expect(t, !c_set, "a NULL blob scans as the nil variant")

    testing.expect_value(t, step(sel), Result.Done)
}

@(test)
test_bind_rejects_multi_variant_union :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT :a")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    // Only `Maybe` is admitted; a real sum type has no single column form.
    Params :: struct {
        a: union {
            i64,
            string,
        },
    }

    _, err := bind_prepare(st, Params)
    testing.expect_value(t, err, Bind_Error.Unsupported_Type)
}
