package sqlgen

import "core:mem"
import "core:strings"

import "libs:bindings/sqlite"
import "tools:gen"

// One field of a resolved query's params or row, unwrapped — `Maybe`-wrapping is
// the emitter's job (writing straight into its builder), same reason
// `base_type_for` never allocates for the schema-driven shapes.
Resolved_Field :: struct {
    name:      string,
    odin_type: string,
    required:  bool,
}

Resolved_Query :: struct {
    def:    Query_Def,
    params: []Resolved_Field,
    row:    []Resolved_Field,
}

// Release the field names `query_resolve` cloned. `def` is untouched — it's the
// caller's `Query_Def`, owned and freed by `query_defs_destroy`, not by this.
// `odin_type` is never freed here: it's either borrowed from `def`'s own cloned
// annotation or a `scalar_type` literal, never an allocation of its own.
resolved_query_destroy :: proc(q: Resolved_Query, allocator := context.allocator) {
    for f in q.params {
        delete(f.name, allocator)
    }

    delete(q.params, allocator)

    for f in q.row {
        delete(f.name, allocator)
    }

    delete(q.row, allocator)
}

// Prepare `def.sql` against the real schema and resolve every param and result
// column: params always from an explicit annotation (SQLite reports no type for
// a bind parameter); result columns from an annotation, or `column_decltype` +
// `scalar_type` when the column is a plain TEXT/BLOB/REAL table reference and
// unannotated. A computed column (decltype "") and an unannotated INTEGER column
// are both hard errors — the former has no type at all, the latter no type its
// storage class can fix — so neither gets a silent default.
query_resolve :: proc(
    db: ^sqlite.Conn,
    def: Query_Def,
    d: ^gen.Diags,
    allocator := context.allocator,
) -> (
    resolved: Resolved_Query,
    ok: bool,
) {
    assert(db != nil, "query_resolve needs a connection")

    st, prep := sqlite.prepare(db, def.sql)

    if prep != .Ok {
        gen.diagf(d, gen.Pos{}, "%s: %s does not prepare against the real schema", def.name, def.sql)

        return {}, false
    }

    defer sqlite.finalize(st)

    field_by_name := make(map[string]Query_Field, len(def.fields), allocator)
    defer delete(field_by_name)

    for f in def.fields {
        field_by_name[f.name] = f
    }

    all_ok := true

    param_count := sqlite.bind_parameter_count(st)
    params := make([dynamic]Resolved_Field, 0, param_count, allocator)

    for index in 1 ..= param_count {
        marker := sqlite.bind_parameter_name(st, index)

        if len(marker) < 2 {
            gen.diagf(d, gen.Pos{}, "%s: parameter %d is unnamed; only named markers are supported", def.name, index)
            all_ok = false

            continue
        }

        name := marker[1:]
        field, annotated := field_by_name[name]

        if !annotated {
            gen.diagf(d, gen.Pos{}, "%s: param %s has no type annotation", def.name, name)
            all_ok = false

            continue
        }

        // `marker` is borrowed from `st` and dies at finalize; every returned
        // field must own its name past that point.
        owned_name := strings.clone(name, allocator)
        append(&params, Resolved_Field{name = owned_name, odin_type = field.odin_type, required = field.required})
    }

    row := resolve_row(st, field_by_name, def, d, allocator, &all_ok)

    if !all_ok {
        delete(params)
        delete(row)

        return {}, false
    }

    return Resolved_Query{def = def, params = params[:], row = row[:]}, true
}

// The result row's fields, or an empty slice when the query has no columns worth
// a struct: zero columns, or column names that aren't valid Odin identifiers (a
// bare `SELECT 1` reports its column as `"1"`, which no struct field can be).
@(private)
resolve_row :: proc(
    st: ^sqlite.Stmt,
    field_by_name: map[string]Query_Field,
    def: Query_Def,
    d: ^gen.Diags,
    allocator: mem.Allocator,
    all_ok: ^bool,
) -> (
    row: [dynamic]Resolved_Field,
) {
    col_count := sqlite.column_count(st)

    if col_count == 0 {
        return
    }

    for c in 0 ..< col_count {
        if !is_identifier(sqlite.column_name(st, c)) {
            return
        }
    }

    row = make([dynamic]Resolved_Field, 0, col_count, allocator)

    // `column_name` is borrowed from `st` and dies at finalize, same as a bind
    // parameter's marker — every returned field must own its name past that. It's
    // cloned only at each append site, so a rejected column never allocates one
    // it would just orphan.
    for c in 0 ..< col_count {
        name := sqlite.column_name(st, c)

        if field, annotated := field_by_name[name]; annotated {
            append(
                &row,
                Resolved_Field {
                    name = strings.clone(name, allocator),
                    odin_type = field.odin_type,
                    required = field.required,
                },
            )

            continue
        }

        decl := sqlite.column_decltype(st, c)

        if decl == "" {
            gen.diagf(d, gen.Pos{}, "%s: result column %s is computed and has no type annotation", def.name, name)
            all_ok^ = false

            continue
        }

        // Same reason a schema shape's INTEGER column must be annotated: an
        // integer's signedness and wire identity aren't derivable from storage.
        // TEXT/BLOB/REAL map unambiguously and still fall back below.
        if decl == "INTEGER" {
            gen.diagf(
                d,
                gen.Pos{},
                "%s: result column %s (INTEGER) has no type annotation; annotate it (e.g. u64, i64, or a wire.Type)",
                def.name,
                name,
            )
            all_ok^ = false

            continue
        }

        scalar, scalar_ok := scalar_type(decl)

        if !scalar_ok {
            gen.diagf(d, gen.Pos{}, "%s.%s: unmapped storage class %q", def.name, name, decl)
            all_ok^ = false

            continue
        }

        // Nullability isn't derivable from a query's shape alone (a LEFT JOIN can
        // make any column nullable), so an unannotated column defaults to the
        // safe direction rather than guessing not-null.
        append(&row, Resolved_Field{name = strings.clone(name, allocator), odin_type = scalar, required = false})
    }

    return
}
