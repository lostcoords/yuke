package sqlgen

import "core:os"

import "tools:gen"

// Read every `*.sql` file in `dir`, in filename order, and parse each into its
// `-- name:` blocks.
queries_load :: proc(dir: string, d: ^gen.Diags, allocator := context.allocator) -> (defs: []Query_Def, ok: bool) {
    assert(d != nil, "queries_load needs a diagnostic sink")

    paths := gen.list_files(dir, ".sql", d, allocator) or_return
    defer delete(paths)

    out := make([dynamic]Query_Def, 0, allocator)
    all_ok := true

    for path in paths {
        text, read_err := os.read_entire_file_from_path(path, allocator)

        if read_err != nil {
            gen.diagf(d, gen.Pos{file = path}, "cannot read query file")
            all_ok = false
            delete(path, allocator)

            continue
        }

        file_defs, parse_ok := parse_queries(string(text), allocator)
        delete(text, allocator)

        if !parse_ok {
            gen.diagf(d, gen.Pos{file = path}, "cannot parse query file")
            all_ok = false
            delete(path, allocator)

            continue
        }

        for def in file_defs {
            append(&out, def)
        }

        delete(file_defs)
        delete(path, allocator)
    }

    if !all_ok {
        query_defs_destroy(out[:], allocator)

        return nil, false
    }

    return out[:], true
}
