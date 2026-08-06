package sqlgen

import "core:os"
import "core:strings"

import "libs:bindings/sqlite"
import "tools:gen"

// One column `pragma_table_info` reports for a table, in declared order.
Column :: struct {
    name:     string,
    type:     string,
    not_null: bool,
}

@(private)
Table_Info_Params :: struct {
    table_name: string,
}

// Read every `*.sql` file in `dir`, in filename order, and apply it to a fresh
// `:memory:` connection — the same order `migrations_apply` runs them in
// production, since our own migration files are already numbered for it.
// `sources` maps each applied path to its text, for `column_annotation` to search.
schema_build :: proc(
    dir: string,
    d: ^gen.Diags,
    allocator := context.allocator,
) -> (
    db: ^sqlite.Conn,
    sources: map[string]string,
    ok: bool,
) {
    assert(d != nil, "schema_build needs a diagnostic sink")

    // Each element's string data is either handed off into `text_by_path` below
    // or freed at the point it is abandoned, so this defer never double-frees or
    // leaks an element — only the slice header is unconditionally ours.
    paths := gen.list_files(dir, ".sql", d, allocator) or_return
    defer delete(paths, allocator)

    if len(paths) == 0 {
        gen.diagf(d, gen.Pos{file = dir}, "no migration files found")

        return nil, nil, false
    }

    opened, open_rc := sqlite.open_memory()

    if open_rc != .Ok {
        gen.diagf(d, gen.Pos{file = dir}, "cannot open the in-memory schema database")

        for path in paths {
            delete(path, allocator)
        }

        return nil, nil, false
    }

    text_by_path := make(map[string]string, len(paths), allocator)

    for path in paths {
        text, read_err := os.read_entire_file_from_path(path, allocator)

        if read_err != nil {
            gen.diagf(d, gen.Pos{file = path}, "cannot read migration file")
            delete(path, allocator)

            continue
        }

        sql := string(text)
        text_by_path[path] = sql

        if rc := sqlite.exec(opened, sql); rc != .Ok {
            gen.diagf(d, gen.Pos{file = path}, "migration failed to apply")
        }
    }

    if gen.diags_failed(d) {
        sqlite.close(opened)

        for path, text in text_by_path {
            delete(text, allocator)
            delete(path, allocator)
        }

        delete(text_by_path)

        return nil, nil, false
    }

    return opened, text_by_path, true
}

// The columns `table` has, in declared order — SQLite's own answer, not a parse of
// our DDL.
table_columns :: proc(
    db: ^sqlite.Conn,
    table: string,
    allocator := context.allocator,
) -> (
    columns: []Column,
    ok: bool,
) {
    assert(db != nil, "table_columns needs a connection")
    assert(len(table) > 0, "table_columns needs a table name")

    // `notnull` is quoted: unquoted it is SQLite's postfix `NOTNULL` operator, not
    // a column reference, and the statement fails to parse.
    st, prep := sqlite.prepare(
        db,
        `SELECT name, type, "notnull" AS not_null FROM pragma_table_info(:table_name) ORDER BY cid`,
    )

    if prep != .Ok {
        return nil, false
    }

    defer sqlite.finalize(st)

    reader, reader_err := sqlite.reader_prepare(st, Table_Info_Params, Column, allocator)

    if reader_err != .None {
        return nil, false
    }

    defer sqlite.reader_destroy(&reader, allocator)

    params := Table_Info_Params {
        table_name = table,
    }
    rows, read_err := sqlite.read_all(&reader, &params, allocator)

    return rows, read_err == nil && len(rows) > 0
}

// The `-- wire.Type` comment trailing `column`'s declaration in `source`, within the
// `CREATE TABLE table (...)` block — text search over our own DDL, not SQL parsing.
// Absent means the caller falls back to a plain scalar type for `column`.
column_annotation :: proc(source: string, table: string, column: string) -> (odin_type: string, found: bool) {
    header := strings.concatenate({"CREATE TABLE ", table, " ("}, context.temp_allocator)
    start := strings.index(source, header)

    if start < 0 {
        return "", false
    }

    body := source[start:]
    lines := strings.split_lines(body, context.temp_allocator)
    end := len(lines)

    for i in 1 ..< len(lines) {
        trimmed := strings.trim_space(lines[i])

        // The table's own closing paren is always alone on its line in our DDL
        // style; a CHECK's nested parens never are.
        if trimmed == ")" || strings.has_prefix(trimmed, ") ") {
            end = i

            break
        }
    }

    for line in lines[:end] {
        trimmed := strings.trim_space(line)

        if !strings.has_prefix(trimmed, column) {
            continue
        }

        // A prefix match must end the identifier: `session_id` must not match
        // inside a line declaring `session_id_high` or similar.
        rest := trimmed[len(column):]

        if len(rest) > 0 && (is_ident_byte(rest[0])) {
            continue
        }

        comment := strings.index(line, "-- ")

        if comment < 0 {
            return "", false
        }

        return strings.trim_space(line[comment + 3:]), true
    }

    return "", false
}

@(private)
is_ident_byte :: proc(b: byte) -> bool {
    return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}
