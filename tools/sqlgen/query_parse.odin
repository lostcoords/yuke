package sqlgen

import "core:strings"

// What primitive a query's generated wrapper (if any) is built from. `Manual`
// queries get their structs generated but no wrapper — their cardinality doesn't
// fit `execute`/`read_one`/`read_all` (a zero-or-one read, a borrowed scan field,
// a bare existence check with no row worth naming).
Cardinality :: enum {
    Exec,
    One,
    Many,
    Manual,
}

// One `-- field: Type` or `-- field: Type!` annotation. `required` false means
// the generated field is `Maybe`-wrapped.
Query_Field :: struct {
    name:      string,
    odin_type: string,
    required:  bool,
}

// One `-- name: X :cardinality` block: its own SQL text and whichever of its
// params/result columns were given an explicit type.
Query_Def :: struct {
    name:        string,
    cardinality: Cardinality,
    sql:         string,
    fields:      []Query_Field,
}

// Split `source` into its `-- name:` blocks. A prose comment line (one that isn't
// `name: X :cardinality` and isn't `field: Type`) is documentation and is
// skipped — this is a fixed two-token grammar, not general SQL comment parsing.
parse_queries :: proc(source: string, allocator := context.allocator) -> (queries: []Query_Def, ok: bool) {
    lines := strings.split_lines(source, allocator)
    defer delete(lines)

    out := make([dynamic]Query_Def, 0, allocator)
    i := 0

    for i < len(lines) {
        name, cardinality, header_ok := parse_header(lines[i])

        if !header_ok {
            // A line that starts the header prefix but doesn't fully parse (a
            // typo'd cardinality, a missing name) means a query silently never
            // making it into the generated file — that's a hard error, not a
            // line to skip past.
            if strings.has_prefix(strings.trim_space(lines[i]), "-- name:") do return nil, false

            i += 1

            continue
        }

        i += 1

        fields := make([dynamic]Query_Field, allocator)

        for i < len(lines) {
            trimmed := strings.trim_space(lines[i])

            if !strings.has_prefix(trimmed, "--") do break

            if _, _, is_header := parse_header(lines[i]); is_header do break

            if field, is_field := parse_field(trimmed); is_field {
                field.name = strings.clone(field.name, allocator)
                field.odin_type = strings.clone(field.odin_type, allocator)
                append(&fields, field)
            }

            i += 1
        }

        body := make([dynamic]string, allocator)

        for i < len(lines) {
            if _, _, is_header := parse_header(lines[i]); is_header do break

            append(&body, lines[i])
            i += 1
        }

        sql := strings.trim_space(strings.join(body[:], "\n", allocator))
        delete(body)

        if len(sql) == 0 do return nil, false

        append(
            &out,
            Query_Def{name = strings.clone(name, allocator), cardinality = cardinality, sql = sql, fields = fields[:]},
        )
    }

    return out[:], true
}

// Release every string `parse_queries` cloned. `main` doesn't bother — the
// process exits right after generating — but a test that parses many times
// under the tracking allocator needs this.
query_defs_destroy :: proc(defs: []Query_Def, allocator := context.allocator) {
    for def in defs {
        for f in def.fields {
            delete(f.name, allocator)
            delete(f.odin_type, allocator)
        }

        delete(def.fields, allocator)
        delete(def.name, allocator)
        delete(def.sql, allocator)
    }

    delete(defs, allocator)
}

// `-- name: X :cardinality`, trimmed of the comment marker.
@(private)
parse_header :: proc(line: string) -> (name: string, cardinality: Cardinality, ok: bool) {
    trimmed := strings.trim_space(line)

    if !strings.has_prefix(trimmed, "-- name:") do return "", .Exec, false

    rest := strings.trim_space(trimmed[len("-- name:"):])
    space := strings.last_index_byte(rest, ' ')

    if space < 0 do return "", .Exec, false

    name = strings.trim_space(rest[:space])
    marker := strings.trim_space(rest[space:])

    switch marker {
    case ":exec":
        cardinality = .Exec
    case ":one":
        cardinality = .One
    case ":many":
        cardinality = .Many
    case ":manual":
        cardinality = .Manual
    case:
        return "", .Exec, false
    }

    if len(name) == 0 do return "", .Exec, false

    return name, cardinality, true
}

// `-- field: Type` or `-- field: Type!`. `field` must be a single identifier —
// a prose comment ("-- Marks only rise...") never matches, since it has no
// colon-delimited leading identifier.
@(private)
parse_field :: proc(trimmed: string) -> (field: Query_Field, ok: bool) {
    body := strings.trim_space(trimmed[2:])
    colon := strings.index_byte(body, ':')

    if colon < 0 do return {}, false

    name := strings.trim_space(body[:colon])

    if !is_identifier(name) do return {}, false

    rest := strings.trim_space(body[colon + 1:])

    if len(rest) == 0 do return {}, false

    required := strings.has_suffix(rest, "!")
    odin_type := strings.trim_space(rest[:len(rest) - 1]) if required else rest

    if len(odin_type) == 0 do return {}, false

    return Query_Field{name = name, odin_type = odin_type, required = required}, true
}

@(private)
is_identifier :: proc(s: string) -> bool {
    if len(s) == 0 do return false

    for b, i in s {
        letter := (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
        digit := b >= '0' && b <= '9'

        if i == 0 && !letter do return false

        if i > 0 && !letter && !digit do return false
    }

    return true
}
