package sqlite

import "base:intrinsics"
import "core:mem"
import "core:testing"

import "libs:testsupport"

@(test)
test_scan_row_maps_tags_using_and_optional_fields :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 7 AS total, 'hello' AS label")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Numbers :: struct {
        count: u16 `sql:"total"`,
    }

    Row :: struct {
        label:         string,
        using numbers: Numbers,
        absent:        i64 `sql:",optional"`,
        ignored:       i64 `sql:"-"`,
    }

    testing.expect_value(t, step(st), Result.Row)

    row := Row {
        absent  = 22,
        ignored = 99,
    }
    err := scan_row(st, &row)
    testing.expect_value(t, err, Scan_Error.None)
    defer scan_destroy(&row)

    testing.expect_value(t, row.label, "hello")
    testing.expect_value(t, row.count, u16(7))
    testing.expect_value(t, row.absent, i64(0))
    testing.expect_value(t, row.ignored, i64(99))

    // The scan owns its string; advancing the statement cannot invalidate it.
    testing.expect_value(t, step(st), Result.Done)
    testing.expect_value(t, row.label, "hello")
}

@(test)
test_scan_row_requires_a_closed_one_to_one_shape :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    Missing :: struct {
        a: i64,
        b: i64,
    }

    Unknown :: struct {
        a: i64,
    }

    Duplicate_Field :: struct {
        a: i64 `sql:"value"`,
        b: i64 `sql:"value"`,
    }

    Invalid_Tag :: struct {
        value: i64 `sql:"value,optional,optional"`,
    }

    Duplicate_Optional :: struct {
        a: i64 `sql:"absent,optional"`,
        b: i64 `sql:"absent,optional"`,
    }

    Unsupported_Optional :: struct {
        value: map[string]int `sql:",optional"`,
    }

    // A column is stored host-endian; a byte-order-specific destination is a
    // different type, not a narrower one, so the shape rejects it up front.
    Foreign_Endian_Float :: struct {
        value: f32le,
    }

    Foreign_Endian_Integer :: struct {
        value: u32be,
    }

    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS a", Missing), Scan_Error.Column_Missing)
    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS a, 2 AS extra", Unknown), Scan_Error.Column_Unknown)
    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS a, 2 AS a", Unknown), Scan_Error.Column_Duplicate)
    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS value", Duplicate_Field), Scan_Error.Column_Duplicate)
    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS value", Invalid_Tag), Scan_Error.Invalid_Tag)
    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS other", Duplicate_Optional), Scan_Error.Column_Duplicate)
    testing.expect_value(
        t,
        scan_test_error(db, "SELECT 1 AS other", Unsupported_Optional),
        Scan_Error.Unsupported_Type,
    )
    testing.expect_value(
        t,
        scan_test_error(db, "SELECT 1.5 AS value", Foreign_Endian_Float),
        Scan_Error.Unsupported_Type,
    )
    testing.expect_value(
        t,
        scan_test_error(db, "SELECT 1 AS value", Foreign_Endian_Integer),
        Scan_Error.Unsupported_Type,
    )
}

@(test)
test_scan_row_rejects_storage_and_destination_range_mismatches :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    Signed :: struct {
        value: i8,
    }

    Unsigned :: struct {
        value: u8,
    }

    Boolean :: struct {
        value: bool,
    }

    Blob :: struct {
        value: [3]byte,
    }

    testing.expect_value(t, scan_test_error(db, "SELECT '1' AS value", Signed), Scan_Error.Storage_Type_Mismatch)
    testing.expect_value(t, scan_test_error(db, "SELECT 128 AS value", Signed), Scan_Error.Value_Out_Of_Range)
    testing.expect_value(t, scan_test_error(db, "SELECT -1 AS value", Unsigned), Scan_Error.Value_Out_Of_Range)
    testing.expect_value(t, scan_test_error(db, "SELECT 2 AS value", Boolean), Scan_Error.Value_Out_Of_Range)
    testing.expect_value(t, scan_test_error(db, "SELECT NULL AS value", Signed), Scan_Error.Null_Not_Allowed)
    testing.expect_value(t, scan_test_error(db, "SELECT x'0102' AS value", Blob), Scan_Error.Value_Out_Of_Range)
}

@(test)
test_scan_row_clones_blob_storage :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT x'0001feff' AS exact, x'aabb' AS bytes")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        exact: [4]byte,
        bytes: []byte,
    }

    testing.expect_value(t, step(st), Result.Row)

    row: Row
    err := scan_row(st, &row)
    testing.expect_value(t, err, Scan_Error.None)
    defer scan_destroy(&row)

    testing.expect_value(t, row.exact, [4]byte{0x00, 0x01, 0xfe, 0xff})
    testing.expect_value(t, len(row.bytes), 2)
    testing.expect_value(t, row.bytes[0], byte(0xaa))
    testing.expect_value(t, row.bytes[1], byte(0xbb))

    testing.expect_value(t, step(st), Result.Done)
    testing.expect_value(t, len(row.bytes), 2)
    testing.expect_value(t, row.bytes[0], byte(0xaa))
    testing.expect_value(t, row.bytes[1], byte(0xbb))
}

@(test)
test_scan_row_oom_destroys_partial_value :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 'first' AS first, 'second' AS second")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        first:  string,
        second: string,
    }

    testing.expect_value(t, step(st), Result.Row)

    // Tracking under the injector, so the first column's clone is observed being made
    // and then released rather than merely dropped from the returned value.
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)

    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, mem.tracking_allocator(&track), 1)

    row: Row
    err := scan_row(st, &row, testsupport.failing_allocator(&failing))
    testing.expect_value(t, err, Scan_Error.Out_Of_Memory)
    testing.expect_value(t, row, Row{})
    testing.expect_value(t, track.total_allocation_count, i64(1))
    scan_test_expect_no_leaks(t, &track)
}

// A successful scan owns its clones; `scan_destroy` gives every one of them back.
@(test)
test_scan_row_destroy_returns_every_clone :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 'text' AS label, x'aabb' AS bytes, 3 AS count")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        label: string,
        bytes: []byte,
        count: i64,
    }

    testing.expect_value(t, step(st), Result.Row)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    row: Row
    err := scan_row(st, &row, tracked)
    testing.expect_value(t, err, Scan_Error.None)
    testing.expect_value(t, len(track.allocation_map), 2)

    scan_destroy(&row, tracked)
    testing.expect_value(t, row.label, "")
    testing.expect(t, row.bytes == nil, "a destroyed scan keeps no slice")
    testing.expect_value(t, row.count, i64(0))
    scan_test_expect_no_leaks(t, &track)
}

@(test)
test_scan_requires_an_empty_destination :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 'new' AS label")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)
    testing.expect_value(t, step(st), Result.Row)

    Row :: struct {
        label: string,
    }

    row := Row {
        label = "already owned",
    }
    testing.expect_assert(t, "scan destination must own nothing")
    _ = scan_row(st, &row)
}

// One resolved shape drives every row: the mapping is built once and each step scans
// through it, with the same ownership the one-shot path has.
@(test)
test_scan_mapping_reuses_one_resolved_shape :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 1 AS n, 'one' AS label UNION ALL SELECT 2, 'two' ORDER BY n")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        n:     i64,
        label: string,
    }

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    mapping, mapping_err := scan_prepare(st, Row, tracked)
    testing.expect_value(t, mapping_err, Scan_Error.None)
    testing.expect_value(t, len(mapping.binds), 2)

    for expected in ([2]Row{{n = 1, label = "one"}, {n = 2, label = "two"}}) {
        testing.expect_value(t, step(st), Result.Row)

        row: Row
        err := scan(&mapping, &row, tracked)
        testing.expect_value(t, err, Scan_Error.None)
        testing.expect_value(t, row.n, expected.n)
        testing.expect_value(t, row.label, expected.label)

        scan_destroy(&row, tracked)
    }

    testing.expect_value(t, step(st), Result.Done)

    scan_mapping_destroy(&mapping, tracked)
    testing.expect(t, mapping.statement == nil, "a destroyed mapping keeps no statement")
    scan_test_expect_no_leaks(t, &track)
}

// An absent optional column is resolved once, not searched for on every row.
@(test)
test_scan_mapping_resolves_absent_optional_columns :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 5 AS present")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        present: i64,
        absent:  string `sql:",optional"`,
    }

    mapping, mapping_err := scan_prepare(st, Row)
    testing.expect_value(t, mapping_err, Scan_Error.None)
    defer scan_mapping_destroy(&mapping)

    testing.expect_value(t, len(mapping.binds), 2)
    testing.expect_value(t, mapping.binds[1].col, -1)
    testing.expect_value(t, step(st), Result.Row)

    row: Row
    err := scan(&mapping, &row)
    testing.expect_value(t, err, Scan_Error.None)
    defer scan_destroy(&row)

    testing.expect_value(t, row.present, i64(5))
    testing.expect_value(t, row.absent, "")
}

// A destination that does not match the query is diagnosed at prepare time, so no row
// ever pays for the check.
@(test)
test_scan_prepare_rejects_a_mismatched_destination :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 1 AS a, 2 AS b")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Partial :: struct {
        a: i64,
    }

    Extra :: struct {
        a: i64,
        b: i64,
        c: i64,
    }

    // No row was stepped: the shape alone decides.
    partial, partial_err := scan_prepare(st, Partial)
    testing.expect_value(t, partial_err, Scan_Error.Column_Unknown)
    testing.expect(t, partial.binds == nil, "a rejected prepare allocates nothing")

    extra, extra_err := scan_prepare(st, Extra)
    testing.expect_value(t, extra_err, Scan_Error.Column_Missing)
    testing.expect(t, extra.binds == nil, "a rejected prepare allocates nothing")
}

// A borrowed field costs no allocation and owns nothing; only the cloned column is
// tracked, and releasing the row must not hand SQLite's memory to the allocator.
@(test)
test_scan_row_borrows_without_cloning :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    st, prep := prepare(db, "SELECT 'peek' AS view, 'keep' AS owned, x'aabb' AS raw")
    testing.expect_value(t, prep, Result.Ok)
    defer testing.expect_value(t, finalize(st), Result.Ok)

    Row :: struct {
        view:  string `sql:",borrowed"`,
        owned: string,
        raw:   []byte `sql:",borrowed"`,
    }

    testing.expect_value(t, step(st), Result.Row)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    row: Row
    err := scan_row(st, &row, tracked)
    testing.expect_value(t, err, Scan_Error.None)
    testing.expect_value(t, row.view, "peek")
    testing.expect_value(t, row.owned, "keep")
    testing.expect_value(t, len(row.raw), 2)
    testing.expect_value(t, track.total_allocation_count, i64(1))

    scan_destroy(&row, tracked)
    testing.expect_value(t, row.view, "")
    testing.expect(t, row.raw == nil, "a destroyed scan keeps no borrow")
    scan_test_expect_no_leaks(t, &track)
}

// Borrowing is only defined where a clone would otherwise happen; on a by-value
// destination it would silently mean nothing, so the tag is rejected.
@(test)
test_scan_row_rejects_borrowing_a_by_value_field :: proc(t: ^testing.T) {
    db, rc := open_memory()
    testing.expect_value(t, rc, Result.Ok)
    defer testing.expect_value(t, close(db), Result.Ok)

    Borrowed_Integer :: struct {
        value: i64 `sql:",borrowed"`,
    }

    Repeated_Option :: struct {
        value: string `sql:",borrowed,borrowed"`,
    }

    testing.expect_value(t, scan_test_error(db, "SELECT 1 AS value", Borrowed_Integer), Scan_Error.Invalid_Tag)
    testing.expect_value(t, scan_test_error(db, "SELECT 'x' AS value", Repeated_Option), Scan_Error.Invalid_Tag)
}

scan_test_expect_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}

scan_test_error :: proc(db: ^Conn, sql: string, $T: typeid) -> Scan_Error where intrinsics.type_is_struct(T) {
    assert(db != nil, "scan test needs a database")
    assert(len(sql) > 0, "scan test needs SQL")

    st, prep := prepare(db, sql)
    assert(prep == .Ok, "scan test SQL prepares")
    defer finalize(st)

    assert(step(st) == .Row, "scan test SQL returns a row")

    row: T
    err := scan_row(st, &row)

    // A shape failure can be an invalid tag, which the release walker asserts against;
    // only a successful scan owns anything to release.
    if err == .None {
        scan_destroy(&row)
    }

    return err
}
