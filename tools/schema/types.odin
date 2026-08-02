package schema

import "core:odin/ast"
import "core:slice"
import "core:strings"

// Types declared in the wire package that are not protocol payloads. They are decoder
// scaffolding or encoder configuration, and the marker rules do not apply to them.
@(rodata)
NON_WIRE_TYPES := [?]string{"Emitter", "Decoder", "Limits", "Close_Codes", "Server_Frame_Header"}

// Scalar bases a wire type alias may wrap.
@(rodata)
SCALAR_BASES := [?]string{"string", "bool", "u64", "i64", "u32", "i32", "u16", "i16", "u8", "i8", "f64", "f32"}

// Walk every declaration and fill the type graph. Enum wire tables are collected first,
// because an enum is only part of the protocol if a table maps it to wire strings.
types_collect :: proc(m: ^Model, ps: ^Package_Source, d: ^Diags) {
    assert(m != nil, "types_collect needs a model")
    assert(ps != nil, "types_collect needs a package source")

    tables := tables_collect(ps)
    nullable := nullable_members(ps)
    tristate := tristate_unions(ps)

    for &s in ps.files {
        for decl in s.file.decls {
            v, is_single := decl_single(decl)

            if !is_single || v.is_mutable {
                continue
            }

            name := expr_text(&s, v.names[0])

            if slice.contains(NON_WIRE_TYPES[:], name) {
                continue
            }

            #partial switch t in v.values[0].derived {
            case ^ast.Struct_Type:
                append(&m.structs, struct_read(m, &s, nullable, tristate, name, v, t, d))

            case ^ast.Union_Type:
                append(&m.unions, union_read(&s, ps, name, v, t, d))

            case ^ast.Enum_Type:
                table, has_table := tables[name]

                // An enum with no mapping table never reaches the wire; leaving it out
                // of the model is deliberate, not an omission.
                if !has_table {
                    continue
                }

                append(&m.enums, enum_read(&s, name, v, t, table, d))

            case ^ast.Distinct_Type:
                append(&m.aliases, alias_read(m, &s, name, expr_text(&s, t.type), v, d))

            case ^ast.Ident:
                // `Model_Id :: string` and friends. A bound declared on the alias is the
                // only one its fields carry, so skipping these would drop it silently.
                if slice.contains(SCALAR_BASES[:], t.name) {
                    append(&m.aliases, alias_read(m, &s, name, t.name, v, d))
                }
            }
        }
    }
}

// One `[Enum]string` or `[Enum]i32` mapping table.
Wire_Table :: struct {
    // Table variable name (`method_name_wire`).
    name:    string,

    // Enum member -> wire string, or the decimal text of the number.
    entries: map[string]string,
    numeric: bool,
}

// Collect every `<name> := [Enum]string{…}` / `[Enum]i32{…}` table, keyed by enum type.
tables_collect :: proc(ps: ^Package_Source) -> map[string]Wire_Table {
    out: map[string]Wire_Table

    for &s in ps.files {
        for decl in s.file.decls {
            v, is_single := decl_single(decl)

            if !is_single || !v.is_mutable {
                continue
            }

            lit, is_lit := v.values[0].derived.(^ast.Comp_Lit)

            if !is_lit || lit.type == nil {
                continue
            }

            array, is_array := lit.type.derived.(^ast.Array_Type)

            if !is_array || array.len == nil {
                continue
            }

            enum_name := expr_text(&s, array.len)
            elem := expr_text(&s, array.elem)

            if elem != "string" && elem != "i32" {
                continue
            }

            table := Wire_Table {
                name    = expr_text(&s, v.names[0]),
                numeric = elem == "i32",
            }

            for e in lit.elems {
                fv, is_fv := e.derived.(^ast.Field_Value)

                if !is_fv {
                    continue
                }

                member := strings.trim_prefix(expr_text(&s, fv.field), ".")
                value := expr_text(&s, fv.value)
                table.entries[member] = unquote(value)
            }

            // A second table over the same enum is a diagnostic name map, not a wire
            // form; the first one wins and `error_code_name` is filtered by its `i32`
            // sibling being registered first.
            if enum_name not_in out {
                out[enum_name] = table
            }
        }
    }

    return out
}

// Read a struct declaration and every field's marker, doc, and presence.
struct_read :: proc(
    m: ^Model,
    s: ^Source,
    nullable: map[string]map[string]bool,
    tristate: map[string]bool,
    name: string,
    v: ^ast.Value_Decl,
    t: ^ast.Struct_Type,
    d: ^Diags,
) -> Struct_Def {
    decl_pos := source_pos(s, v.pos.line)

    doc_group_check(v.docs, decl_pos, name, "(declaration)", d)

    def := Struct_Def {
        name = name,
        doc  = comment_text(v.docs),
        pos  = decl_pos,
    }

    if t.fields == nil {
        return def
    }

    own := nullable[wire_snake_case(name, context.temp_allocator)]
    fields := make([dynamic]Field, 0, len(t.fields.list))

    for f in t.fields.list {
        if len(f.names) == 0 {
            continue
        }

        field_name := expr_text(s, f.names[0])
        // The marker requirement follows the declared type; the artifact records the wire
        // type. A `bit_set` needs no marker — its cardinality is its enum's — but it is an
        // array on the wire.
        declared := expr_text(s, f.type)
        type_expr := wire_type_expr(declared)
        pos := source_pos(s, f.pos.line)

        doc_group_check(f.docs, pos, name, field_name, d)

        bound, doc := marker_read(m, f.docs, declared, pos, name, field_name, d)
        declared_presence, default_expr, has_presence := presence_marker_read(f.docs, pos, name, field_name, d)
        const_expr, const_value := const_marker_read(m, f.docs, pos, name, field_name, d)
        delivery_role := delivery_role_read(f.docs, pos, name, field_name, d)

        presence := Presence.Required

        if strings.has_prefix(type_expr, "Maybe(") {
            presence = .Optional
        } else if tristate[type_expr] {
            presence = .Tristate
        }

        if own[field_name] && (!has_presence || declared_presence != .Required_Nullable) {
            diagf(d, pos, "%s.%s uses a required-null emitter but lacks @required-nullable", name, field_name)
        }

        if has_presence {
            switch declared_presence {
            case .Optional, .Required_Nullable:
                if !strings.has_prefix(type_expr, "Maybe(") {
                    diagf(
                        d,
                        pos,
                        "%s.%s declares nullable/optional presence on non-Maybe type %s",
                        name,
                        field_name,
                        type_expr,
                    )
                }

            case .Tristate:
                if !tristate[type_expr] {
                    diagf(d, pos, "%s.%s declares @tristate on non-tristate type %s", name, field_name, type_expr)
                }

            case .Defaulted:
                if strings.has_prefix(type_expr, "Maybe(") {
                    diagf(d, pos, "%s.%s declares a decoder default on a Maybe type", name, field_name)
                }

            case .Required:
            }

            presence = declared_presence
        }

        append(
            &fields,
            Field {
                name = field_name,
                type_expr = type_expr,
                doc = doc,
                bound = bound,
                presence = presence,
                default_expr = default_expr,
                const_expr = const_expr,
                const_value = const_value,
                delivery_role = delivery_role,
                pos = pos,
            },
        )
    }

    def.fields = fields[:]

    return def
}

// Members written with `field_required_null_*`, keyed by the snake-case name of the type
// that owns them. The field marker is authoritative; this AST index catches a dedicated
// helper drifting away from its declaration.
//
// Attribution follows the emitter, not a name: a union arm's members are written inside the
// union's `*_emit` type switch, so a struct with no emitter of its own still gets its
// members from the clause that names it.
nullable_members :: proc(ps: ^Package_Source) -> map[string]map[string]bool {
    out: map[string]map[string]bool

    for name, ref in ps.procs {
        if !strings.has_suffix(name, "_emit") {
            continue
        }

        owner := strings.trim_suffix(name, "_emit")
        record_nullable(&out, owner, calls_in(ref.source, ref.body, nil, "field_required_null_"))

        clauses, found := switch_clauses(ref.body)

        if !found {
            continue
        }

        for clause in clauses {
            if len(clause.list) != 1 {
                continue
            }

            // Retained as a key of the returned map, so this outlives any temp scope.
            arm := wire_snake_case(expr_text(ref.source, clause.list[0]))
            record_nullable(&out, arm, calls_in_stmts(ref.source, clause.body, nil, "field_required_null_"))
        }
    }

    return out
}

record_nullable :: proc(out: ^map[string]map[string]bool, owner: string, calls: []Call_Match) {
    for call in calls {
        if len(call.args) < 2 {
            continue
        }

        if owner not_in out {
            out[owner] = make(map[string]bool)
        }

        members := &out[owner]
        members[unquote(call.args[1])] = true
    }
}

// Read a field's bounds marker from its doc comment. A marker must be its own `//` line;
// a bound mentioned inside a prose sentence is not a declaration, which is exactly the
// mistake this rule exists to catch.
marker_read :: proc(
    m: ^Model,
    docs: ^ast.Comment_Group,
    type_expr: string,
    pos: Pos,
    owner: string,
    field: string,
    d: ^Diags,
) -> (
    bound: Bound,
    doc: string,
) {
    lines := comment_lines(docs, context.temp_allocator)
    prose: [dynamic]string
    defer delete(prose)

    for line in lines {
        if kind, expr, is_marker := marker_parse(line); is_marker {
            if bound.kind != .Missing {
                diagf(d, pos, "%s.%s declares more than one bounds marker", owner, field)

                continue
            }

            bound.kind = kind
            bound.expr = expr

            continue
        }

        if _, _, is_presence := presence_marker_parse(line); is_presence {
            continue
        }

        if strings.has_prefix(line, "@const ") {
            continue
        }

        if strings.has_prefix(line, "@delivery ") {
            continue
        }

        append(&prose, line)
    }

    doc = strings.join(prose[:], " ")

    if bound.kind == .Bounded || bound.kind == .Fixed {
        value, ok := bound_resolve(m, bound.expr)
        bound.value = value

        if !ok {
            diagf(
                d,
                pos,
                "%s.%s has marker `@%s %s` that does not resolve to a constant",
                owner,
                field,
                bound.kind == .Bounded ? "bounded" : "fixed",
                bound.expr,
            )
        }
    }

    // Strings and arrays are what a length rule applies to; anything else legitimately
    // has none.
    if bound.kind == .Missing && needs_bound(type_expr) {
        diagf(d, pos, "%s.%s is a %s with no @bounded/@fixed/@unbounded marker", owner, field, type_expr)
    }

    return bound, doc
}

// Read an explicit wire-presence declaration. Presence is protocol data when the
// Odin type cannot express it, so conflicting markers are a hard diagnostic.
presence_marker_read :: proc(
    docs: ^ast.Comment_Group,
    pos: Pos,
    owner: string,
    field: string,
    d: ^Diags,
) -> (
    presence: Presence,
    default_expr: string,
    ok: bool,
) {
    for line in comment_lines(docs, context.temp_allocator) {
        parsed, expr, is_marker := presence_marker_parse(line)

        if !is_marker {
            continue
        }

        if ok {
            diagf(d, pos, "%s.%s declares more than one presence marker", owner, field)

            continue
        }

        presence = parsed
        default_expr = expr
        ok = true
    }

    return
}

presence_marker_parse :: proc(line: string) -> (presence: Presence, expr: string, ok: bool) {
    switch line {
    case "@optional":
        return .Optional, "", true
    case "@required-nullable":
        return .Required_Nullable, "", true
    case "@tristate":
        return .Tristate, "", true
    }

    if strings.has_prefix(line, "@default ") {
        expr := strings.trim_space(strings.trim_prefix(line, "@default "))

        return .Defaulted, expr, expr != ""
    }

    return .Required, "", false
}

const_marker_read :: proc(
    m: ^Model,
    docs: ^ast.Comment_Group,
    pos: Pos,
    owner: string,
    field: string,
    d: ^Diags,
) -> (
    expr: string,
    value: Maybe(int),
) {
    for line in comment_lines(docs, context.temp_allocator) {
        if !strings.has_prefix(line, "@const ") {
            continue
        }

        if expr != "" {
            diagf(d, pos, "%s.%s declares more than one @const marker", owner, field)

            continue
        }

        expr = strings.trim_space(strings.trim_prefix(line, "@const "))
        resolved, ok := bound_resolve(m, expr)

        if !ok {
            diagf(d, pos, "%s.%s has @const expression `%s` that does not resolve", owner, field, expr)

            continue
        }

        value = resolved
    }

    return
}

delivery_role_read :: proc(docs: ^ast.Comment_Group, pos: Pos, owner: string, field: string, d: ^Diags) -> string {
    role := ""

    for line in comment_lines(docs, context.temp_allocator) {
        if !strings.has_prefix(line, "@delivery ") {
            continue
        }

        if role != "" {
            diagf(d, pos, "%s.%s declares more than one @delivery role", owner, field)

            continue
        }

        role = strings.trim_space(strings.trim_prefix(line, "@delivery "))
    }

    return role
}

// Parse one doc line as a marker.
marker_parse :: proc(line: string) -> (kind: Bound_Kind, expr: string, ok: bool) {
    if line == "@unbounded" {
        return .Unbounded, "", true
    }

    if strings.has_prefix(line, "@bounded ") {
        return .Bounded, strings.trim_space(strings.trim_prefix(line, "@bounded ")), true
    }

    if strings.has_prefix(line, "@fixed ") {
        return .Fixed, strings.trim_space(strings.trim_prefix(line, "@fixed ")), true
    }

    return .Missing, "", false
}

// Unions with an arm meaning "the member was omitted". That arm, not the wrapper's name, is
// what makes a field tri-state: absent, explicit null, and a value are three states, and the
// owner's emitter skips the field entirely for the default arm.
tristate_unions :: proc(ps: ^Package_Source) -> map[string]bool {
    out: map[string]bool

    for &s in ps.files {
        for decl in s.file.decls {
            v, is_single := decl_single(decl)

            if !is_single || v.is_mutable {
                continue
            }

            u, is_union := v.values[0].derived.(^ast.Union_Type)

            if !is_union {
                continue
            }

            for variant in u.variants {
                if strings.has_suffix(expr_text(&s, variant), "_Default") {
                    out[expr_text(&s, v.names[0])] = true
                    break
                }
            }
        }
    }

    return out
}

// The declared type as the wire sees it. `bit_set[E]` is emitted as an array of `E`'s wire
// strings, so it is recorded as `[]E` — the raw Odin spelling would name a type no consumer
// can resolve.
wire_type_expr :: proc(type_expr: string) -> string {
    if !strings.has_prefix(type_expr, "bit_set[") || !strings.has_suffix(type_expr, "]") {
        return type_expr
    }

    inner := type_expr[len("bit_set["):len(type_expr) - 1]

    return strings.concatenate({"[]", inner})
}

// Whether a declared type carries a length a marker must state.
needs_bound :: proc(type_expr: string) -> bool {
    if type_expr == "string" || type_expr == "Maybe(string)" {
        return true
    }

    return strings.has_prefix(type_expr, "[]") || strings.has_prefix(type_expr, "Maybe([]")
}

// Read a union and the member its decoder scans for. An empty discriminator means the arm
// is chosen from outside the payload, which is true of the frame envelopes.
union_read :: proc(
    s: ^Source,
    ps: ^Package_Source,
    name: string,
    v: ^ast.Value_Decl,
    t: ^ast.Union_Type,
    d: ^Diags,
) -> Union_Def {
    known := make(map[string]bool, len(t.variants), context.temp_allocator)
    arms := make([dynamic]Union_Arm, 0, len(t.variants))

    for variant in t.variants {
        arm := expr_text(s, variant)
        known[arm] = true
        append(&arms, Union_Arm{type = arm})
    }

    discriminator := union_discriminator(ps, name)

    if discriminator == "" {
        union_arm_forms(ps, name, &arms)

        is_tristate := false

        for arm in arms {
            if strings.has_suffix(arm.type, "_Default") {
                is_tristate = true
                break
            }
        }

        if is_tristate {
            absent, nulls, values := 0, 0, 0

            for arm in arms {
                switch arm.form {
                case .Absent:
                    absent += 1
                case .Null:
                    nulls += 1
                case .Value:
                    values += 1
                case .None:
                }
            }

            if absent != 1 || nulls != 1 || values != 1 {
                diagf(
                    d,
                    source_pos(s, v.pos.line),
                    "%s tristate emitter must expose exactly one absent, null, and value arm",
                    name,
                )
            }
        }
    } else {
        tags := union_arm_tags(ps, name, known, source_pos(s, v.pos.line), d)

        for &arm in arms {
            tag, has := tags[arm.type]

            if !has {
                diagf(
                    d,
                    source_pos(s, v.pos.line),
                    "%s arm %s has no `%s` value in its decoder",
                    name,
                    arm.type,
                    discriminator,
                )

                continue
            }

            arm.tag = tag
        }
    }

    decl_pos := source_pos(s, v.pos.line)

    doc_group_check(v.docs, decl_pos, name, "(declaration)", d)

    return Union_Def {
        name = name,
        doc = comment_text(v.docs),
        arms = arms[:],
        discriminator = discriminator,
        pos = decl_pos,
    }
}

// What each arm of an untagged union writes, read from the union's emitter. The emit switch
// says it directly: no value writer means the member is omitted, `val_null` means null, and any
// other `val_*` names the scalar type the arm carries.
//
// This is the fact a tri-state field cannot be encoded without, and it is not in the
// declaration — `Maybe(T)` and a three-arm union look the same from the type alone.
union_arm_forms :: proc(ps: ^Package_Source, union_name: string, arms: ^[dynamic]Union_Arm) {
    emitter := strings.concatenate(
        {wire_snake_case(union_name, context.temp_allocator), "_emit"},
        context.temp_allocator,
    )
    ref, has := ps.procs[emitter]

    if !has {
        return
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        return
    }

    for clause in clauses {
        if len(clause.list) != 1 {
            continue
        }

        arm_type := expr_text(ref.source, clause.list[0])
        writers := calls_in_stmts(ref.source, clause.body, nil, "val_")
        // An empty clause writes nothing, so the member is omitted. A clause that writes no
        // scalar is emitting a nested object and is not a tri-state arm at all — left
        // unclassified rather than called absent, which would be a false fact.
        form := len(clause.body) == 0 ? Arm_Form.Absent : Arm_Form.None
        wire_type := ""

        for writer in writers {
            if writer.name == "val_null" {
                form = .Null

                break
            }

            form = .Value
            wire_type = strings.trim_prefix(writer.name, "val_")

            break
        }

        for &arm in arms {
            if arm.type != arm_type {
                continue
            }

            arm.form = form
            arm.wire_type = wire_type
        }
    }
}

// Arm type -> discriminator value, read from the union's decoder. The decoder switches on the
// tag it scanned for, so a clause's labels are the wire values and the arms it returns are the
// types they select.
//
// One clause may serve several tags and return several arms; those are told apart by the
// `tag == "x"` guard the decoder uses. Any pairing this cannot establish is a diagnostic, never
// a guess: a wrong tag would put an unconstructable variant into every generated SDK.
union_arm_tags :: proc(
    ps: ^Package_Source,
    union_name: string,
    known: map[string]bool,
    pos: Pos,
    d: ^Diags,
) -> map[string]string {
    out: map[string]string
    reader := strings.concatenate(
        {wire_snake_case(union_name, context.temp_allocator), "_from_reader"},
        context.temp_allocator,
    )
    ref, has := ps.procs[reader]

    if !has {
        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        return out
    }

    for clause in clauses {
        tags := clause_string_labels(ref.source, clause)

        if len(tags) == 0 {
            continue
        }

        arms := returned_arms(ref.source, ps, clause, known)

        if len(arms) == 0 {
            continue
        }

        if len(tags) == 1 {
            out[arms[0].arm] = tags[0]

            continue
        }

        // Several tags in one clause: take each guarded return, then pair whatever is left
        // only when exactly one tag and one arm remain.
        unclaimed_tags := make([dynamic]string, 0, len(tags), context.temp_allocator)
        unclaimed_arms := make([dynamic]string, 0, len(arms), context.temp_allocator)
        claimed: map[string]bool

        for arm in arms {
            if arm.guard != "" {
                out[arm.arm] = arm.guard
                claimed[arm.guard] = true

                continue
            }

            append(&unclaimed_arms, arm.arm)
        }

        for tag in tags {
            if tag not_in claimed {
                append(&unclaimed_tags, tag)
            }
        }

        if len(unclaimed_tags) == 1 && len(unclaimed_arms) == 1 {
            out[unclaimed_arms[0]] = unclaimed_tags[0]

            continue
        }

        if len(unclaimed_tags) != 0 || len(unclaimed_arms) != 0 {
            diagf(
                d,
                pos,
                "%s has a decoder clause serving %d tags this tool cannot pair with its arms",
                union_name,
                len(tags),
            )
        }
    }

    return out
}

// The tag member a union's decoder scans for, read from its `dec_find_tag` call. Empty
// means the arm is chosen from outside the payload, which is true of the frame envelopes.
union_discriminator :: proc(ps: ^Package_Source, type_name: string) -> string {
    name := strings.concatenate({wire_snake_case(type_name), "_from_reader"}, context.temp_allocator)
    ref, has := ps.procs[name]

    if !has {
        return ""
    }

    for call in calls_in(ref.source, ref.body, {"dec_find_tag"}) {
        if len(call.args) >= 2 {
            return unquote(call.args[1])
        }
    }

    return ""
}

// Read an enum's members and pair each with its wire form. A member missing from the
// table is a hole in a closed set, so it fails rather than being skipped.
enum_read :: proc(
    s: ^Source,
    name: string,
    v: ^ast.Value_Decl,
    t: ^ast.Enum_Type,
    table: Wire_Table,
    d: ^Diags,
) -> Enum_Def {
    decl_pos := source_pos(s, v.pos.line)

    doc_group_check(v.docs, decl_pos, name, "(declaration)", d)

    def := Enum_Def {
        name    = name,
        doc     = comment_text(v.docs),
        table   = table.name,
        numeric = table.numeric,
        pos     = decl_pos,
    }
    values := make([dynamic]Enum_Value, 0, len(t.fields))

    for member in t.fields {
        member_name := expr_text(s, member)

        // `Enum_Type.fields` are expressions with no `docs` pointer, so the member's
        // documentation comes from the comment group ending on the line above it.
        docs := s.doc_ends[member.pos.line - 1]
        member_pos := source_pos(s, member.pos.line)

        doc_group_check(docs, member_pos, name, member_name, d)

        doc := comment_text(docs)
        wire, has := table.entries[member_name]

        if !has {
            diagf(d, source_pos(s, member.pos.line), "%s.%s has no entry in %s", name, member_name, table.name)
        }

        append(&values, Enum_Value{name = member_name, wire = wire, doc = doc})
    }

    def.values = values[:]

    return def
}

// Read a `distinct` scalar newtype and the marker on its declaration.
alias_read :: proc(m: ^Model, s: ^Source, name: string, base: string, v: ^ast.Value_Decl, d: ^Diags) -> Alias_Def {
    pos := source_pos(s, v.pos.line)

    doc_group_check(v.docs, pos, name, "(declaration)", d)

    bound, doc := marker_read(m, v.docs, "", pos, name, "(declaration)", d)

    return Alias_Def{name = name, base = base, doc = doc, bound = bound, pos = pos}
}
