package sqlgen

import "core:fmt"
import "core:os"

import "libs:bindings/sqlite"
import "tools:gen"

Options :: struct {
    migrations:  string,
    queries:     string,
    queries_out: string,
    check:       bool,
    quiet:       bool,
}

USAGE :: "usage: sqlgen --migrations <dir> --queries <dir> --queries-out <file> [--check] [--quiet]"

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintfln(USAGE)
        os.exit(2)
    }

    opts, args_ok := options_parse(os.args[1:])

    if !args_ok {
        fmt.eprintfln(USAGE)
        os.exit(2)
    }

    d: gen.Diags

    db, sources, build_ok := schema_build(opts.migrations, &d)

    if !build_ok {
        gen.diags_report(&d)
        os.exit(1)
    }

    defer sqlite.close(db)

    columns_by_table := make(map[string][]Column)

    for shape in GENERATED_SHAPES {
        if shape.table in columns_by_table {
            continue
        }

        columns, columns_ok := table_columns(db, shape.table)

        if !columns_ok {
            gen.diagf(&d, gen.Pos{file = opts.migrations}, "%s: no such table", shape.table)

            continue
        }

        columns_by_table[shape.table] = columns
    }

    if gen.diags_failed(&d) {
        gen.diags_report(&d)
        os.exit(1)
    }

    defs, load_ok := queries_load(opts.queries, &d)

    if !load_ok {
        gen.diags_report(&d)
        os.exit(1)
    }

    resolved := make([]Resolved_Query, len(defs))

    for def, i in defs {
        query, resolve_ok := query_resolve(db, def, &d)

        if !resolve_ok {
            continue
        }

        resolved[i] = query
    }

    if gen.diags_failed(&d) {
        gen.diags_report(&d)
        os.exit(1)
    }

    data, generate_ok := generate_queries(GENERATED_SHAPES, columns_by_table, sources, resolved, &d)

    if !generate_ok {
        gen.diags_report(&d)
        os.exit(1)
    }

    gen.emit(data, opts.queries_out, opts.check, &d)

    if gen.diags_failed(&d) {
        gen.diags_report(&d)
        os.exit(1)
    }

    if !opts.quiet {
        fmt.printfln(
            "%s  %d bytes  %d shapes  %d queries",
            opts.queries_out,
            len(data),
            len(GENERATED_SHAPES),
            len(resolved),
        )
    }
}

options_parse :: proc(args: []string) -> (opts: Options, ok: bool) {
    opts.migrations = "src/daemon/store/migrations"
    opts.queries = "src/daemon/store/queries"
    opts.queries_out = "src/daemon/store/queries/queries_gen.odin"
    i := 0

    for i < len(args) {
        switch args[i] {
        case "--migrations":
            if i + 1 >= len(args) {
                return opts, false
            }

            opts.migrations = args[i + 1]
            i += 2

        case "--queries":
            if i + 1 >= len(args) {
                return opts, false
            }

            opts.queries = args[i + 1]
            i += 2

        case "--queries-out":
            if i + 1 >= len(args) {
                return opts, false
            }

            opts.queries_out = args[i + 1]
            i += 2

        case "--check":
            opts.check = true
            i += 1

        case "--quiet":
            opts.quiet = true
            i += 1

        case:
            return opts, false
        }
    }

    return opts, true
}
