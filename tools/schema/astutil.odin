package schema

import "core:odin/ast"
import "core:strings"

// One call site's arguments, as source text.
Call_Match :: struct {
    // Callee identifier.
    name: string,

    // Argument expressions in order, sliced out of the owning file's source.
    args: []string,
}

// Collector state threaded through `ast.walk` via `Visitor.data`.
Call_Scan :: struct {
    src:    string,
    prefix: string,
    names:  []string,
    out:    ^[dynamic]Call_Match,
}

// Every call in `body` whose callee is one of `names` or begins with `prefix`. An empty
// `prefix` matches nothing extra; empty `names` selects on the prefix alone.
//
// Matched as AST nodes rather than as text: a needle like `dec_find_tag(d, "` would encode
// the decoder's parameter name, and both it and `len(` would match inside comments and
// string literals. A silently missing fact is the one failure this tool must not have.
calls_in :: proc(
    s: ^Source,
    body: ^ast.Stmt,
    names: []string,
    prefix := "",
    allocator := context.temp_allocator,
) -> []Call_Match {
    assert(s != nil, "calls_in needs the owning source")

    out := make([dynamic]Call_Match, 0, 8, allocator)

    if body == nil {
        return out[:]
    }

    scan := Call_Scan {
        src    = s.file.src,
        prefix = prefix,
        names  = names,
        out    = &out,
    }
    v := ast.Visitor {
        visit = visit_calls,
        data  = &scan,
    }
    ast.walk(&v, body)

    return out[:]
}

visit_calls :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    if v == nil || node == nil {
        return v
    }

    scan := (^Call_Scan)(v.data)
    call, is_call := node.derived.(^ast.Call_Expr)

    if !is_call {
        return v
    }

    name := callee_name(call)

    if name == "" {
        return v
    }

    matched := scan.prefix != "" && strings.has_prefix(name, scan.prefix)

    if !matched {
        for candidate in scan.names {
            if candidate == name {
                matched = true
                break
            }
        }
    }

    if !matched {
        return v
    }

    args := make([dynamic]string, 0, len(call.args), context.temp_allocator)

    for arg in call.args {
        append(&args, node_text(scan.src, arg))
    }

    append(scan.out, Call_Match{name = name, args = args[:]})

    return v
}

// Every call in a statement list, for a type-switch clause body.
calls_in_stmts :: proc(
    s: ^Source,
    stmts: []^ast.Stmt,
    names: []string,
    prefix := "",
    allocator := context.temp_allocator,
) -> []Call_Match {
    assert(s != nil, "calls_in_stmts needs the owning source")

    out := make([dynamic]Call_Match, 0, 8, allocator)
    scan := Call_Scan {
        src    = s.file.src,
        prefix = prefix,
        names  = names,
        out    = &out,
    }
    v := ast.Visitor {
        visit = visit_calls,
        data  = &scan,
    }

    for stmt in stmts {
        ast.walk(&v, stmt)
    }

    return out[:]
}

// Collector state for `len(x) > BOUND` comparisons.
Cap_Scan :: struct {
    src: string,
    out: ^[dynamic]string,
}

// The right-hand side of every `len(…) > <bound>` comparison in `body`, as source text.
// This is how the package spells a collection cap.
len_caps_in :: proc(s: ^Source, body: ^ast.Stmt, allocator := context.temp_allocator) -> []string {
    assert(s != nil, "len_caps_in needs the owning source")

    out := make([dynamic]string, 0, 4, allocator)

    if body == nil {
        return out[:]
    }

    scan := Cap_Scan {
        src = s.file.src,
        out = &out,
    }
    v := ast.Visitor {
        visit = visit_len_caps,
        data  = &scan,
    }
    ast.walk(&v, body)

    return out[:]
}

visit_len_caps :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    if v == nil || node == nil {
        return v
    }

    scan := (^Cap_Scan)(v.data)
    binary, is_binary := node.derived.(^ast.Binary_Expr)

    if !is_binary || binary.op.text != ">" || binary.left == nil {
        return v
    }

    call, is_call := binary.left.derived.(^ast.Call_Expr)

    if !is_call || callee_name(call) != "len" {
        return v
    }

    append(scan.out, node_text(scan.src, binary.right))

    return v
}

// The callee's identifier, or "" when the call is not a plain named call. A type
// conversion parses as a call too, so this also names the target of `Some_Type(x)`.
callee_name :: proc(call: ^ast.Call_Expr) -> string {
    if call == nil || call.expr == nil {
        return ""
    }

    ident, is_ident := call.expr.derived.(^ast.Ident)

    return is_ident ? ident.name : ""
}

// Source slice for any node, guarded so a node from another file yields "" rather than a
// wrong slice.
node_text :: proc(src: string, node: ^ast.Node) -> string {
    if node == nil {
        return ""
    }

    if node.pos.offset < 0 || node.end.offset > len(src) || node.pos.offset >= node.end.offset {
        return ""
    }

    return src[node.pos.offset:node.end.offset]
}

// `Ada_Case` type name to the `snake_case` prefix its sibling procedures use. Allocated
// for the model's lifetime: the result is retained as a delivery class.
wire_snake_case :: proc(name: string, allocator := context.allocator) -> string {
    out, err := strings.to_snake_case(name, allocator)
    assert(err == nil, "the snake-case conversion allocates")

    return out
}

// Strip one layer of surrounding double quotes from a string literal's source text. The slice
// borrows the file buffer, so an escape would have to be decoded into a new string; the wire
// tables and markers this reads have none, and the assert is what keeps that true.
unquote :: proc(text: string) -> string {
    if len(text) >= 2 && text[0] == '"' && text[len(text) - 1] == '"' {
        inner := text[1:len(text) - 1]
        assert(!strings.contains(inner, "\\"), "a wire string literal with an escape cannot be borrowed")

        return inner
    }

    return text
}

// Case clauses of the first `switch` (or `switch x in y`) in `body`. The protocol
// registries all live in exactly one switch per procedure.
switch_clauses :: proc(
    body: ^ast.Stmt,
    allocator := context.temp_allocator,
) -> (
    clauses: []^ast.Case_Clause,
    ok: bool,
) {
    if body == nil {
        return nil, false
    }

    block, is_block := body.derived_stmt.(^ast.Block_Stmt)

    if !is_block {
        return nil, false
    }

    for stmt in block.stmts {
        switch_body: ^ast.Stmt

        #partial switch v in stmt.derived_stmt {
        case ^ast.Switch_Stmt:
            switch_body = v.body

        case ^ast.Type_Switch_Stmt:
            switch_body = v.body
        }

        if switch_body == nil {
            continue
        }

        clause_block, body_is_block := switch_body.derived_stmt.(^ast.Block_Stmt)

        if !body_is_block {
            continue
        }

        out := make([dynamic]^ast.Case_Clause, 0, len(clause_block.stmts), allocator)

        for clause_stmt in clause_block.stmts {
            if clause, is_clause := clause_stmt.derived_stmt.(^ast.Case_Clause); is_clause {
                append(&out, clause)
            }
        }

        return out[:], true
    }

    return nil, false
}

// `.Session_Create` -> `Session_Create`, for a case label or a returned enum member.
enum_member_name :: proc(e: ^ast.Expr) -> string {
    if e == nil {
        return ""
    }

    sel, is_sel := e.derived.(^ast.Implicit_Selector_Expr)

    if !is_sel || sel.field == nil {
        return ""
    }

    return sel.field.name
}

// A single-name, single-value declaration, which is the shape every protocol declaration
// in the wire package takes. Callers test `is_mutable` themselves: `::` declares types and
// constants, `:=` declares the wire mapping tables.
decl_single :: proc(decl: ^ast.Stmt) -> (v: ^ast.Value_Decl, ok: bool) {
    value, is_value := decl.derived_stmt.(^ast.Value_Decl)

    if !is_value || len(value.names) != 1 || len(value.values) != 1 {
        return nil, false
    }

    return value, true
}

// String literal labels of a case clause, unquoted. A tag-dispatch clause labels on the
// discriminator's wire strings.
clause_string_labels :: proc(s: ^Source, clause: ^ast.Case_Clause, allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, 0, len(clause.list), allocator)

    for label in clause.list {
        lit, is_lit := label.derived.(^ast.Basic_Lit)

        if !is_lit {
            continue
        }

        text := expr_text(s, label)

        if len(text) >= 2 && text[0] == '"' {
            append(&out, unquote(text))
        }
    }

    return out[:]
}

// Collector state for returned union arms.
Return_Scan :: struct {
    src:   string,
    ps:    ^Package_Source,
    arms:  ^[dynamic]Returned_Arm,
    known: map[string]bool,
}

// One `return <arm>` inside a tag-dispatch clause, with the tag its enclosing `tag == "x"`
// guard names, if any.
Returned_Arm :: struct {
    arm:   string,
    guard: string,
}

// Union arms returned inside `clause`, in source order. A clause returns either a composite
// literal of the arm type or a local bound from a helper, so both are resolved.
returned_arms :: proc(
    s: ^Source,
    ps: ^Package_Source,
    clause: ^ast.Case_Clause,
    known: map[string]bool,
    allocator := context.temp_allocator,
) -> []Returned_Arm {
    out := make([dynamic]Returned_Arm, 0, 2, allocator)
    locals := local_result_types(s, ps, clause)

    for stmt in clause.body {
        collect_returns(s, ps, stmt, known, locals, "", &out)
    }

    return out[:]
}

// Locals in a clause, mapped to their type. Two shapes carry a union arm: a binding from a
// helper (`um := _user_message_body(d)`) and a typed declaration the clause then fills in
// (`st: Tool_State_Running`).
local_result_types :: proc(s: ^Source, ps: ^Package_Source, clause: ^ast.Case_Clause) -> map[string]string {
    out := make(map[string]string, 4, context.temp_allocator)

    for stmt in clause.body {
        v, is_value := stmt.derived_stmt.(^ast.Value_Decl)

        if !is_value || len(v.names) != 1 {
            continue
        }

        name := expr_text(s, v.names[0])

        if v.type != nil && len(v.values) == 0 {
            out[name] = expr_text(s, v.type)

            continue
        }

        if len(v.values) != 1 {
            continue
        }

        target := call_target_name(v.values[0])

        if target == "" {
            continue
        }

        if ref, known := ps.procs[target]; known && ref.result_type != "" {
            out[name] = ref.result_type
        }
    }

    return out
}

// Walk a clause's statements for `return` results naming a union arm. `guard` carries the tag
// of an enclosing `tag == "x"` comparison, which is how a clause serving two tags tells them
// apart.
collect_returns :: proc(
    s: ^Source,
    ps: ^Package_Source,
    stmt: ^ast.Stmt,
    known: map[string]bool,
    locals: map[string]string,
    guard: string,
    out: ^[dynamic]Returned_Arm,
) {
    if stmt == nil {
        return
    }

    #partial switch v in stmt.derived_stmt {
    case ^ast.Return_Stmt:
        if len(v.results) == 0 {
            return
        }

        if arm := returned_arm_name(s, v.results[0], known, locals); arm != "" {
            append(out, Returned_Arm{arm = arm, guard = guard})
        }

    case ^ast.Block_Stmt:
        for inner in v.stmts {
            collect_returns(s, ps, inner, known, locals, guard, out)
        }

    case ^ast.If_Stmt:
        inner_guard := tag_comparison(s, v.cond)
        collect_returns(s, ps, v.body, known, locals, inner_guard != "" ? inner_guard : guard, out)
        collect_returns(s, ps, v.else_stmt, known, locals, guard, out)
    }
}

// The arm a return result names: a composite literal's type, or a local's resolved type.
returned_arm_name :: proc(s: ^Source, e: ^ast.Expr, known: map[string]bool, locals: map[string]string) -> string {
    if e == nil {
        return ""
    }

    #partial switch v in e.derived {
    case ^ast.Comp_Lit:
        name := expr_text(s, v.type)

        return name in known ? name : ""

    case ^ast.Ident:
        resolved, has := locals[v.name]

        return has && resolved in known ? resolved : ""
    }

    return ""
}

// The literal in a `tag == "x"` comparison, or "" when `cond` is not one.
tag_comparison :: proc(s: ^Source, cond: ^ast.Expr) -> string {
    if cond == nil {
        return ""
    }

    binary, is_binary := cond.derived.(^ast.Binary_Expr)

    if !is_binary || binary.op.text != "==" {
        return ""
    }

    if expr_text(s, binary.left) != "tag" {
        return ""
    }

    text := expr_text(s, binary.right)

    return len(text) >= 2 && text[0] == '"' ? unquote(text) : ""
}
