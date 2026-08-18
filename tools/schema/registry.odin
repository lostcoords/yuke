package schema

import "core:odin/ast"
import "core:strconv"
import "core:strings"

import "tools:gen"

// Fill methods, broadcasts, and errors.
registry_collect :: proc(m: ^Model, ps: ^Package_Source, d: ^gen.Diags) {
    assert(m != nil, "registry_collect needs a model")
    assert(ps != nil, "registry_collect needs a package source")

    methods := model_enum(m, "Method_Name")
    broadcasts := model_enum(m, "Broadcast_Name")

    if methods == nil do gen.diagf(d, gen.Pos{}, "Method_Name is missing from the model, so no method registry can be built")

    if broadcasts == nil do gen.diagf(d, gen.Pos{}, "Broadcast_Name is missing from the model, so no broadcast registry can be built")

    if methods == nil || broadcasts == nil do return

    params := dispatch_read(m, ps, "request_params_from_reader", d)
    defer delete(params)
    results := dispatch_read(m, ps, "response_result_from_reader", d)
    defer delete(results)
    payloads := dispatch_read(m, ps, "broadcast_data_from_reader", d)
    defer delete(payloads)
    reverse := broadcast_name_reverse(ps, d)
    defer delete(reverse)
    classes := broadcast_classes(ps, d)
    defer delete(classes)
    seq_fields := broadcast_selector_fields(ps, "broadcast_data_seq", d)
    defer delete(seq_fields)
    session_fields := broadcast_selector_fields(ps, "broadcast_data_session_id", d)
    defer delete(session_fields)
    defaults := params_optional_set(ps, d)
    defer delete(defaults)

    for value in methods.values {
        params_type, has_params := params[value.name]
        result_type, has_result := results[value.name]

        if !has_params do gen.diagf(d, methods.pos, "Method_Name.%s has no case in request_params_from_reader", value.name)

        if !has_result do gen.diagf(d, methods.pos, "Method_Name.%s has no case in response_result_from_reader", value.name)

        optional := defaults[value.name]

        append(
            &m.methods,
            Method {
                name = value.name,
                wire = value.wire,
                doc = value.doc,
                params_type = params_type,
                result_type = result_type,
                params_optional = optional,
            },
        )
    }

    for value in broadcasts.values {
        payload, has_payload := payloads[value.name]
        class, has_class := classes[value.name]

        if !has_payload do gen.diagf(d, broadcasts.pos, "Broadcast_Name.%s has no case in broadcast_data_from_reader", value.name)

        if !has_class do gen.diagf(d, broadcasts.pos, "Broadcast_Name.%s has no case in broadcast_name_class", value.name)

        // The forward and reverse maps must agree: the reverse one is what the daemon's
        // pump and resync fold route on, so a disagreement is a live routing bug.
        if has_payload {
            if named, has_named := reverse[payload]; has_named && named != value.name {
                gen.diagf(
                    d,
                    broadcasts.pos,
                    "%s decodes into %s but broadcast_data_name maps that payload to %s",
                    value.name,
                    payload,
                    named,
                )
            }
        }

        append(
            &m.broadcasts,
            Broadcast {
                name = value.name,
                wire = value.wire,
                doc = value.doc,
                params_type = payload,
                class = class,
                seq_field = seq_fields[payload],
                session_field = session_fields[payload],
            },
        )
    }

    delivery_classes_collect(m, ps, d)
    errors_collect(m, ps, d)
}

// Read a `switch method { case .X: <lhs> = <reader>(d) or_return }` dispatch into a map of
// enum member -> payload type.
dispatch_read :: proc(m: ^Model, ps: ^Package_Source, proc_name: string, d: ^gen.Diags) -> map[string]string {
    out: map[string]string
    ref, has := ps.procs[proc_name]

    if !has {
        gen.diagf(d, gen.Pos{}, "%s not found; the method/broadcast linkage cannot be read", proc_name)

        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        gen.diagf(
            d,
            source_pos(ref.source, ref.body.pos.line),
            "%s contains no switch to read the linkage from",
            proc_name,
        )

        return out
    }

    for clause in clauses {
        if len(clause.list) == 0 do continue

        pos := source_pos(ref.source, clause.pos.line)
        payload, resolved := case_payload_type(m, ps, clause, ref.source)

        if !resolved {
            gen.diagf(d, pos, "%s has a case body this tool cannot read a payload type from", proc_name)

            continue
        }

        for label in clause.list {
            member := enum_member_name(label)

            if member == "" {
                gen.diagf(d, pos, "%s has a case label that is not an enum member", proc_name)

                continue
            }

            out[member] = payload
        }
    }

    return out
}

// The payload type a dispatch case decodes into.
//
// Two shapes occur. The common one assigns a decoder result directly, and the type comes
// from that decoder's declared return type. The `distinct Part_Delta` broadcasts instead
// bind the decoder to a local and convert it — `pd := part_delta_from_reader(d) or_return`
// then `data = Message_Part_Delta_Data(pd)` — where the payload is the conversion target,
// not the decoder's return type. A conversion to a type the model knows therefore wins
// over the decoder.
case_payload_type :: proc(
    m: ^Model,
    ps: ^Package_Source,
    clause: ^ast.Case_Clause,
    s: ^Source,
) -> (
    payload: string,
    ok: bool,
) {
    targets: [dynamic]string
    defer delete(targets)

    // Only assignments count. A `:=` binding inside the clause is a local step, not the
    // payload, so consulting it would let an unrelated conversion win.
    for stmt in clause.body {
        assign, is_assign := stmt.derived_stmt.(^ast.Assign_Stmt)

        if !is_assign do continue

        for rhs in assign.rhs {
            if name := call_target_name(rhs); name != "" do append(&targets, name)
        }
    }

    for name in targets {
        if is_model_type(m, name) do return name, true
    }

    for name in targets {
        if ref, known := ps.procs[name]; known && ref.result_type != "" do return ref.result_type, true
    }

    return "", false
}

// Whether `name` is a type the model already holds.
is_model_type :: proc(m: ^Model, name: string) -> bool {
    if model_struct(m, name) != nil || model_union(m, name) != nil || model_enum(m, name) != nil do return true

    for a in m.aliases {
        if a.name == name do return true
    }

    return false
}

// The called procedure's name, unwrapping `or_return`.
call_target_name :: proc(e: ^ast.Expr) -> string {
    if e == nil do return ""

    #partial switch v in e.derived {
    case ^ast.Or_Return_Expr:
        return call_target_name(v.expr)

    case ^ast.Call_Expr:
        ident, is_ident := v.expr.derived.(^ast.Ident)

        if !is_ident do return ""

        return ident.name
    }

    return ""
}

// Payload type -> the member carrying its sequence number, read from `broadcast_data_seq`. The
// accessor names the field per arm, so this is the field the daemon stamps rather than a guess
// from a field called `seq`.
broadcast_selector_fields :: proc(ps: ^Package_Source, proc_name: string, d: ^gen.Diags) -> map[string]string {
    out: map[string]string
    ref, has := ps.procs[proc_name]

    if !has {
        gen.diagf(d, gen.Pos{}, "%s not found; broadcast field metadata is incomplete", proc_name)

        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        gen.diagf(d, source_pos(ref.source, ref.body.pos.line), "%s contains no switch", proc_name)

        return out
    }

    for clause in clauses {
        if len(clause.list) != 1 do continue

        arm := expr_text(ref.source, clause.list[0])

        for stmt in clause.body {
            ret, is_return := stmt.derived_stmt.(^ast.Return_Stmt)

            if !is_return || len(ret.results) == 0 do continue

            if sel, is_sel := ret.results[0].derived.(^ast.Selector_Expr); is_sel && sel.field != nil do out[arm] = sel.field.name
        }
    }

    return out
}

// Read `broadcast_data_name`'s type switch into payload type -> broadcast member. This is
// the reverse of `broadcast_data_from_reader` and the pairing the daemon routes on.
broadcast_name_reverse :: proc(ps: ^Package_Source, d: ^gen.Diags) -> map[string]string {
    out: map[string]string
    ref, has := ps.procs["broadcast_data_name"]

    if !has {
        gen.diagf(d, gen.Pos{}, "broadcast_data_name not found; the payload/name pairing cannot be verified")

        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        gen.diagf(d, source_pos(ref.source, ref.body.pos.line), "broadcast_data_name contains no switch")

        return out
    }

    for clause in clauses {
        if len(clause.list) != 1 do continue

        arm := expr_text(ref.source, clause.list[0])
        member := return_first_enum_member(clause)

        if arm != "" && member != "" do out[arm] = member
    }

    return out
}

// The enum member in a clause's `return .X, true`.
return_first_enum_member :: proc(clause: ^ast.Case_Clause) -> string {
    for stmt in clause.body {
        ret, is_return := stmt.derived_stmt.(^ast.Return_Stmt)

        if !is_return || len(ret.results) == 0 do continue

        if name := enum_member_name(ret.results[0]); name != "" do return name
    }

    return ""
}

// Read `broadcast_name_class` into broadcast member -> delivery class. Cases list several
// members at once, so every label in a clause takes the clause's returned class.
broadcast_classes :: proc(ps: ^Package_Source, d: ^gen.Diags) -> map[string]string {
    out: map[string]string
    ref, has := ps.procs["broadcast_name_class"]

    if !has {
        gen.diagf(d, gen.Pos{}, "broadcast_name_class not found; delivery classes cannot be read")

        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        gen.diagf(d, source_pos(ref.source, ref.body.pos.line), "broadcast_name_class contains no switch")

        return out
    }

    for clause in clauses {
        if len(clause.list) == 0 do continue

        class := return_first_enum_member(clause)

        if class == "" {
            gen.diagf(
                d,
                source_pos(ref.source, clause.pos.line),
                "broadcast_name_class has a case that returns no class",
            )

            continue
        }

        class_name := wire_snake_case(class)

        for label in clause.list {
            if member := enum_member_name(label); member != "" do out[member] = class_name
        }
    }

    return out
}

// Methods whose `params` member may be omitted, read from `default_params`. The final bare
// `case:` returns nil for every other method and contributes no labels.
params_optional_set :: proc(ps: ^Package_Source, d: ^gen.Diags) -> map[string]bool {
    out: map[string]bool
    ref, has := ps.procs["default_params"]

    if !has {
        gen.diagf(d, gen.Pos{}, "default_params not found; omitted-params methods cannot be read")

        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        gen.diagf(d, source_pos(ref.source, ref.body.pos.line), "default_params contains no switch")

        return out
    }

    for clause in clauses {
        for label in clause.list {
            if member := enum_member_name(label); member != "" do out[member] = true
        }
    }

    return out
}

// Collect the delivery classes and their rules. Gating and droppability each come from their own
// exhaustive switch in the protocol package, the single statement of each rule. Sequencing is
// observed from the broadcasts themselves: a class is sequenced when its members carry a sequence
// field.
delivery_classes_collect :: proc(m: ^Model, ps: ^Package_Source, d: ^gen.Diags) {
    gated := broadcast_class_rule(ps, "broadcast_class_gated", d)
    defer delete(gated)
    droppable := broadcast_class_rule(ps, "broadcast_class_droppable", d)
    defer delete(droppable)
    seen: map[string]bool
    defer delete(seen)

    for b in m.broadcasts {
        if b.class in seen do continue

        seen[b.class] = true
        sequenced := false

        for other in m.broadcasts {
            if other.class == b.class && other.seq_field != "" {
                sequenced = true

                break
            }
        }

        is_gated, gated_known := gated[b.class]
        is_droppable, droppable_known := droppable[b.class]

        if !gated_known do gen.diagf(d, gen.Pos{}, "delivery class %s has no case in broadcast_class_gated", b.class)

        if !droppable_known do gen.diagf(d, gen.Pos{}, "delivery class %s has no case in broadcast_class_droppable", b.class)

        append(
            &m.delivery_classes,
            Delivery_Class{name = b.class, gated = is_gated, droppable = is_droppable, sequenced = sequenced},
        )
    }
}

// Delivery class -> the boolean `accessor` returns for it. Each delivery rule has one exhaustive
// switch in the protocol package, so this reads the rule rather than inferring it from a name.
broadcast_class_rule :: proc(ps: ^Package_Source, accessor: string, d: ^gen.Diags) -> map[string]bool {
    out: map[string]bool
    ref, has := ps.procs[accessor]

    if !has {
        gen.diagf(d, gen.Pos{}, "%s not found; the delivery rule it states cannot be read", accessor)

        return out
    }

    clauses, found := switch_clauses(ref.body)

    if !found {
        gen.diagf(d, gen.Pos{}, "%s contains no switch", accessor)

        return out
    }

    for clause in clauses {
        // Only a lone bare `true`/`false` is readable. A computed expression, or a case returning
        // both, is a rule this cannot state, so it fails instead of taking the last return.
        value, sole := sole_bool_return(ref, clause)

        if !sole {
            gen.diagf(
                d,
                source_pos(ref.source, clause.pos.line),
                "%s has a case this tool cannot read a boolean from",
                accessor,
            )

            continue
        }

        for label in clause.list {
            if member := enum_member_name(label); member != "" do out[wire_snake_case(member)] = value
        }
    }

    return out
}

// The value of a clause's single `return true`/`return false`, or `sole = false` for anything else.
sole_bool_return :: proc(ref: Proc_Ref, clause: ^ast.Case_Clause) -> (value: bool, sole: bool) {
    for stmt in clause.body {
        ret, is_return := stmt.derived_stmt.(^ast.Return_Stmt)

        if !is_return || len(ret.results) == 0 do continue

        if sole do return false, false

        text := expr_text(ref.source, ret.results[0])

        if text != "true" && text != "false" do return false, false

        value, sole = text == "true", true
    }

    return value, sole
}

// Pair `Error_Code` members with their durable JSON-RPC numbers.
errors_collect :: proc(m: ^Model, ps: ^Package_Source, d: ^gen.Diags) {
    codes := model_enum(m, "Error_Code")

    if codes == nil {
        gen.diagf(d, gen.Pos{}, "Error_Code is missing from the model, so no error registry can be built")

        return
    }

    if !codes.numeric do gen.diagf(d, codes.pos, "Error_Code is mapped by %s, which is not the numeric wire table", codes.table)

    for value in codes.values {
        number, ok := parse_i32(value.wire)

        if !ok {
            gen.diagf(d, codes.pos, "Error_Code.%s maps to %q, which is not a number", value.name, value.wire)

            continue
        }

        append(&m.errors, Error_Def{name = value.name, doc = value.doc, code = number})
    }
}

parse_i32 :: proc(text: string) -> (out: i32, ok: bool) {
    n := strconv.parse_i64_of_base(strings.trim_space(text), 10) or_return

    if n < i64(min(i32)) || n > i64(max(i32)) do return 0, false

    return i32(n), true
}
