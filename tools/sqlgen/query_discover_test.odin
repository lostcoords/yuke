package sqlgen

import "core:os"
import "core:path/filepath"
import "core:testing"

import "tools:gen"

@(test)
test_queries_load_reads_every_file_in_order :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "yuke-sqlgen-queries-*", context.temp_allocator)
    testing.expect(t, dir_err == nil, "make_directory_temp failed")
    defer os.remove_all(dir)

    first, first_join_err := filepath.join({dir, "0001_first.sql"}, context.temp_allocator)
    testing.expect(t, first_join_err == nil)
    testing.expect(
        t,
        os.write_entire_file(first, transmute([]byte)string("-- name: First :exec\nDELETE FROM t;\n")) == nil,
    )
    defer os.remove(first)

    second, second_join_err := filepath.join({dir, "0002_second.sql"}, context.temp_allocator)
    testing.expect(t, second_join_err == nil)
    testing.expect(
        t,
        os.write_entire_file(second, transmute([]byte)string("-- name: Second :exec\nDELETE FROM u;\n")) == nil,
    )
    defer os.remove(second)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    defs, ok := queries_load(dir, &d)
    defer query_defs_destroy(defs)
    testing.expect(t, ok)
    testing.expect(t, !gen.diags_failed(&d))
    testing.expect_value(t, len(defs), 2)
    testing.expect_value(t, defs[0].name, "First")
    testing.expect_value(t, defs[1].name, "Second")
}

@(test)
test_queries_load_reports_a_file_that_fails_to_parse :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "yuke-sqlgen-queries-*", context.temp_allocator)
    testing.expect(t, dir_err == nil, "make_directory_temp failed")
    defer os.remove_all(dir)

    broken, join_err := filepath.join({dir, "0001_broken.sql"}, context.temp_allocator)
    testing.expect(t, join_err == nil)
    testing.expect(t, os.write_entire_file(broken, transmute([]byte)string("-- name: Empty :exec\n")) == nil)
    defer os.remove(broken)

    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := queries_load(dir, &d)
    testing.expect(t, !ok, "a header with no SQL body fails the whole load")
    testing.expect(t, gen.diags_failed(&d))
}
