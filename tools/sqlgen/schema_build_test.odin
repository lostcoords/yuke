package sqlgen

import "core:os"
import "core:path/filepath"
import "core:testing"

import "libs:bindings/sqlite"
import "tools:gen"

@(test)
test_schema_build_applies_migrations_in_filename_order :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "yuke-sqlgen-*", context.temp_allocator)
    testing.expect(t, dir_err == nil, "make_directory_temp failed")
    defer os.remove_all(dir)

    first, first_join_err := filepath.join({dir, "0001_first.sql"}, context.temp_allocator)
    testing.expect(t, first_join_err == nil)
    testing.expect(t, os.write_entire_file(first, transmute([]byte)string("CREATE TABLE t (a INTEGER);")) == nil)
    defer os.remove(first)

    second, second_join_err := filepath.join({dir, "0002_second.sql"}, context.temp_allocator)
    testing.expect(t, second_join_err == nil)
    testing.expect(t, os.write_entire_file(second, transmute([]byte)string("ALTER TABLE t ADD COLUMN b TEXT;")) == nil)
    defer os.remove(second)

    d: gen.Diags
    defer gen.diags_destroy(&d)
    db, sources, ok := schema_build(dir, &d)
    testing.expect(t, ok, "two well-formed migrations apply cleanly")
    testing.expect(t, !gen.diags_failed(&d))
    defer sqlite.close(db)
    defer delete(sources)
    defer for path, text in sources {
        delete(text)
        delete(path)
    }

    testing.expect_value(t, len(sources), 2)
    testing.expect(t, sources[first] == "CREATE TABLE t (a INTEGER);", "the first file's text is kept")
    testing.expect(t, sources[second] != "", "the second file's text is kept")

    // Both statements landed, in order: `b` only exists because 0002 ran after 0001.
    columns, columns_ok := table_columns(db, "t")
    defer delete(columns)
    defer for &col in columns {
        sqlite.scan_destroy(&col)
    }
    testing.expect(t, columns_ok)
    testing.expect_value(t, len(columns), 2)
    testing.expect_value(t, columns[1].name, "b")
}

@(test)
test_schema_build_reports_a_migration_that_fails_to_apply :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "yuke-sqlgen-*", context.temp_allocator)
    testing.expect(t, dir_err == nil, "make_directory_temp failed")
    defer os.remove_all(dir)

    broken, join_err := filepath.join({dir, "0001_broken.sql"}, context.temp_allocator)
    testing.expect(t, join_err == nil)
    testing.expect(t, os.write_entire_file(broken, transmute([]byte)string("NOT VALID SQL;")) == nil)
    defer os.remove(broken)

    d: gen.Diags
    defer gen.diags_destroy(&d)
    db, sources, ok := schema_build(dir, &d)
    testing.expect(t, !ok, "invalid SQL is reported, not silently skipped")
    testing.expect(t, gen.diags_failed(&d))
    testing.expect(t, db == nil)
    testing.expect(t, sources == nil)
}

@(test)
test_schema_build_reports_an_empty_directory :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "yuke-sqlgen-*", context.temp_allocator)
    testing.expect(t, dir_err == nil, "make_directory_temp failed")
    defer os.remove_all(dir)

    d: gen.Diags
    defer gen.diags_destroy(&d)
    db, sources, ok := schema_build(dir, &d)
    testing.expect(t, !ok, "no migrations means nothing to introspect")
    testing.expect(t, gen.diags_failed(&d))
    testing.expect(t, db == nil)
    testing.expect(t, sources == nil)
}
