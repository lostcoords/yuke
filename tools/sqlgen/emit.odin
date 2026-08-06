package sqlgen

import "core:fmt"
import "core:slice"
import "core:strings"

import "tools:gen"

// One `field: type,` line, `Maybe`-wrapped unless `required` — the one place both
// the schema-shape and the query-file struct emitters actually agree, despite
// resolving their fields from unrelated sources.
@(private)
emit_struct_field :: proc(b: ^strings.Builder, name: string, odin_type: string, required: bool) {
    if required {
        fmt.sbprintfln(b, "    %s: %s,", name, odin_type)
    } else {
        fmt.sbprintfln(b, "    %s: Maybe(%s),", name, odin_type)
    }
}

// One shape's resolved fields, in the table's own column order minus `exclude` —
// pure computation, no emission, so the caller can fingerprint them against every
// other struct before deciding whether this shape needs its own declaration.
@(private)
shape_fields :: proc(
    shape: Shape,
    columns: []Column,
    sources: map[string]string,
    d: ^gen.Diags,
    allocator := context.allocator,
) -> (
    fields: []Resolved_Field,
    ok: bool,
) {
    all_ok := true

    // A typo'd exclude would silently leave the column it meant to drop in the
    // generated struct, so an exclude naming no real column is an error, not a no-op.
    for excluded in shape.exclude {
        found := false

        for col in columns {
            if col.name == excluded {
                found = true

                break
            }
        }

        if !found {
            gen.diagf(
                d,
                gen.Pos{},
                "%s: shape %s excludes %q, which is not a column of %s",
                shape.table,
                shape.name,
                excluded,
                shape.table,
            )
            all_ok = false
        }
    }

    out := make([dynamic]Resolved_Field, 0, len(columns), allocator)

    for col in columns {
        if slice.contains(shape.exclude, col.name) {
            continue
        }

        base, base_ok := base_type_for(shape, col, sources, d)

        if !base_ok {
            all_ok = false

            continue
        }

        append(&out, Resolved_Field{name = col.name, odin_type = base, required = col.not_null})
    }

    if !all_ok {
        delete(out)

        return nil, false
    }

    return out[:], true
}

// The Odin type one column's value takes, unwrapped: its `-- wire.Type` annotation if
// the migration that created `shape.table` carries one for it, else a plain scalar
// mapped from PRAGMA's storage class. Never allocates — a substring of `sources` or a
// `scalar_type` literal either way — so the caller decides `Maybe`-wrapping without
// anything here to free.
@(private)
base_type_for :: proc(
    shape: Shape,
    col: Column,
    sources: map[string]string,
    d: ^gen.Diags,
) -> (
    odin_type: string,
    ok: bool,
) {
    for _, source in sources {
        annotated, has_annotation := column_annotation(source, shape.table, col.name)

        if has_annotation {
            return annotated, true
        }
    }

    // No annotation, and INTEGER's Odin type isn't derivable from the storage
    // class (see `scalar_type`): require the `-- Type` comment rather than guess
    // `u64` for what may be signed or a distinct wire id.
    if col.type == "INTEGER" {
        gen.diagf(
            d,
            gen.Pos{},
            "%s.%s: INTEGER column has no `-- Type` annotation; annotate it (e.g. u64, i64, or a wire.Type)",
            shape.table,
            col.name,
        )

        return "", false
    }

    scalar, scalar_ok := scalar_type(col.type)

    if !scalar_ok {
        gen.diagf(d, gen.Pos{}, "%s.%s: unmapped storage class %q", shape.table, col.name, col.type)

        return "", false
    }

    return scalar, true
}
