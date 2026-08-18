package sqlite

import "core:mem"

// Why `read_one` refused to produce a row: the statement's result set held zero
// rows or more than one, not exactly one.
Read_Error :: enum {
    None,
    Row_Count,
}

// What a `Reader` call can fail with: a step that errored, a row that could not
// be materialized, or a row count `read_one` cannot use.
Error :: union #shared_nil {
    Result,
    Scan_Error,
    Read_Error,
}

// A statement resolved for both directions at once: `bind` feeds it its
// parameters, `scan` reads its rows. Bundles what a read call site otherwise
// carries as three separate handles.
Reader :: struct($P, $T: typeid) {
    statement: ^Stmt,
    bind:      Bind_Mapping(P),
    scan:      Scan_Mapping(T),
}

// Resolve both directions of `statement` at once. `P` and `T` are compiled in
// beside the statement they read, so only the scan side's column table can fail
// to allocate at runtime; everything else is a programmer error and asserts.
@(require_results)
reader_prepare :: proc(
    statement: ^Stmt,
    $P, $T: typeid,
    allocator := context.allocator,
) -> (
    reader: Reader(P, T),
    err: Scan_Error,
) {
    assert(statement != nil, "reader_prepare needs a statement")
    assert(allocator.procedure != nil, "reader_prepare needs an allocator")

    bind_mapping, bind_err := bind_prepare(statement, P)
    assert(bind_err == .None, "reader_prepare's parameter struct matches the statement")

    scan_mapping, scan_err := scan_prepare(statement, T, allocator)
    if scan_err == .Out_Of_Memory do return {}, .Out_Of_Memory

    assert(scan_err == .None, "reader_prepare's row struct matches the statement")

    // A `borrowed` field points into the row `step` produced, and `read_all`/`read_one`
    // both advance or reset past that row before returning to the caller — so a
    // borrowed leaf here would hand back a dangling pointer, never a valid one.
    for b in scan_mapping.binds {
        if b.borrowed {
            scan_mapping_destroy(&scan_mapping, allocator)

            return {}, .Invalid_Tag
        }
    }

    return Reader(P, T){statement = statement, bind = bind_mapping, scan = scan_mapping}, .None
}

// Release a reader's scan side and blank it. `allocator` must be the one supplied
// to `reader_prepare`. The bind side owns no memory and needs no teardown.
reader_destroy :: proc(reader: ^Reader($P, $T), allocator := context.allocator) {
    assert(reader != nil, "reader_destroy needs a reader")

    scan_mapping_destroy(&reader.scan, allocator)
    reader^ = {}
}

// Bind `params` and collect every row into `allocator`. Belongs on a statement
// whose SQL already bounds the row count — nothing here caps it otherwise.
// `cap_hint` presizes the collection when the caller knows that bound. On success
// ownership matches `scan`: nothing is freed here, so pair the result with an arena
// or `scan_destroy` per row. On failure everything collected so far is released
// before returning, so a caller never has to clean up a slice it never received.
@(require_results)
read_all :: proc(
    reader: ^Reader($P, $T),
    params: ^P,
    allocator := context.allocator,
    cap_hint := 0,
) -> (
    rows: []T,
    err: Error,
) {
    assert(reader != nil, "read_all needs a reader")
    assert(reader.statement != nil, "read_all needs a resolved reader")
    assert(allocator.procedure != nil, "read_all needs an allocator")
    assert(cap_hint >= 0, "read_all's capacity hint is never negative")

    defer _ = reset_and_clear(reader.statement)

    bind(&reader.bind, params) or_return

    list, make_err := make([dynamic]T, 0, cap_hint, allocator)
    if make_err != nil do return nil, Scan_Error.Out_Of_Memory

    for {
        result := step(reader.statement)
        if result != .Row {
            if is_error(result) {
                read_all_destroy(&list, allocator)

                return nil, result
            }

            break
        }

        row: T
        if scan_err := scan(&reader.scan, &row, allocator); scan_err != .None {
            read_all_destroy(&list, allocator)

            return nil, scan_err
        }

        if _, append_err := append(&list, row); append_err != nil {
            scan_destroy(&row, allocator)
            read_all_destroy(&list, allocator)

            return nil, Scan_Error.Out_Of_Memory
        }
    }

    return list[:], nil
}

// Release every row `read_all` already collected, and the collection itself, so a
// caller that gets an error never receives a slice it has to clean up.
@(private)
read_all_destroy :: proc(list: ^[dynamic]$T, allocator: mem.Allocator) {
    for &row in list {
        scan_destroy(&row, allocator)
    }

    delete(list^)
}

// Bind `params` and scan exactly one row. Zero rows or more than one both fail as
// `Read_Error.Row_Count`, since a caller asking for one row has nothing useful to
// do with either.
@(require_results)
read_one :: proc(reader: ^Reader($P, $T), params: ^P, allocator := context.allocator) -> (row: T, err: Error) {
    assert(reader != nil, "read_one needs a reader")
    assert(reader.statement != nil, "read_one needs a resolved reader")
    assert(allocator.procedure != nil, "read_one needs an allocator")

    defer _ = reset_and_clear(reader.statement)

    bind(&reader.bind, params) or_return

    first := step(reader.statement)
    if first != .Row do return {}, first if is_error(first) else Read_Error.Row_Count

    scan(&reader.scan, &row, allocator) or_return

    second := step(reader.statement)
    if second != .Done {
        scan_destroy(&row, allocator)

        return {}, second if is_error(second) else Read_Error.Row_Count
    }

    return row, nil
}
