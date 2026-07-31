package schema

import "core:odin/ast"
import "core:strconv"
import "core:strings"

// Fill `m.consts` from top-level `NAME :: <int>` declarations and `m.limits` from the
// `LIMITS` composite literal.
consts_collect :: proc(m: ^Model, ps: ^Package_Source, d: ^Diags) {
    assert(m != nil, "consts_collect needs a model")
    assert(ps != nil, "consts_collect needs a package source")

    // Order matters: literals first so `LIMITS` members can name a constant, then the
    // limits, then a second scan so markers naming `LIMITS.*` resolve.
    consts_scan(m, ps)
    consts_collect_table(m, ps, "LIMITS", &m.limits, d)
    consts_collect_table(m, ps, "CLOSE", &m.close_codes, d)
    consts_scan(m, ps)

    if version, ok := m.consts["PROTOCOL_VERSION"]; ok {
        m.protocol_version = version
    } else {
        diagf(d, Pos{}, "PROTOCOL_VERSION is not a resolvable integer constant")
    }
}

// One walk over every top-level `::` declaration, recording those that evaluate to an
// integer.
consts_scan :: proc(m: ^Model, ps: ^Package_Source) {
    for &s in ps.files {
        for decl in s.file.decls {
            v, is_single := decl_single(decl)

            if !is_single || v.is_mutable {
                continue
            }

            if value, ok := const_eval(m, &s, v.values[0]); ok {
                m.consts[expr_text(&s, v.names[0])] = value

                continue
            }

            if lit, is_lit := v.values[0].derived.(^ast.Basic_Lit); is_lit {
                text := lit.tok.text

                if len(text) >= 2 && text[0] == '"' {
                    m.strings[expr_text(&s, v.names[0])] = unquote(text)
                }
            }
        }
    }
}

// Read a named composite literal of integer members into `out`. `LIMITS` and `CLOSE` are both
// this shape, and a client needs both.
consts_collect_table :: proc(m: ^Model, ps: ^Package_Source, name: string, out: ^map[string]int, d: ^Diags) {
    for &s in ps.files {
        for decl in s.file.decls {
            v, is_single := decl_single(decl)

            if !is_single || v.is_mutable {
                continue
            }

            if expr_text(&s, v.names[0]) != name {
                continue
            }

            lit, is_lit := v.values[0].derived.(^ast.Comp_Lit)

            if !is_lit {
                diagf(d, source_pos(&s, v.pos.line), "%s is not a composite literal", name)

                return
            }

            for elem in lit.elems {
                fv, is_fv := elem.derived.(^ast.Field_Value)

                if !is_fv {
                    diagf(d, source_pos(&s, elem.pos.line), "%s has a member that is not `name = value`", name)

                    continue
                }

                field := expr_text(&s, fv.field)
                value, ok := const_eval(m, &s, fv.value)

                if !ok {
                    diagf(
                        d,
                        source_pos(&s, elem.pos.line),
                        "%s.%s is not a resolvable integer expression (%s)",
                        name,
                        field,
                        expr_text(&s, fv.value),
                    )

                    continue
                }

                out[field] = value
            }

            return
        }
    }

    diagf(d, Pos{}, "no %s declaration found in the wire package", name)
}

// Evaluate the integer subset used by `constants.odin`: decimal and underscored
// literals, identifiers naming already-resolved constants, parentheses, unary minus, and
// `+ - * /`. Anything else returns ok=false so the caller can diagnose precisely.
const_eval :: proc(m: ^Model, s: ^Source, e: ^ast.Expr) -> (value: int, ok: bool) {
    if e == nil {
        return 0, false
    }

    #partial switch v in e.derived {
    case ^ast.Basic_Lit:
        text := strings.trim_space(v.tok.text)
        cleaned, _ := strings.replace_all(text, "_", "", context.temp_allocator)

        return strconv.parse_int(cleaned)

    case ^ast.Ident:
        found, has := m.consts[v.name]

        return found, has

    case ^ast.Selector_Expr:
        // `LIMITS.max_page_size`
        if expr_text(s, v.expr) != "LIMITS" {
            return 0, false
        }

        found, has := m.limits[v.field.name]

        return found, has

    case ^ast.Paren_Expr:
        return const_eval(m, s, v.expr)

    case ^ast.Unary_Expr:
        inner, inner_ok := const_eval(m, s, v.expr)

        if !inner_ok {
            return 0, false
        }

        switch v.op.text {
        case "-":
            return -inner, true

        case "+":
            return inner, true
        }

        return 0, false

    case ^ast.Binary_Expr:
        left, left_ok := const_eval(m, s, v.left)
        right, right_ok := const_eval(m, s, v.right)

        if !left_ok || !right_ok {
            return 0, false
        }

        switch v.op.text {
        case "*":
            return left * right, true

        case "+":
            return left + right, true

        case "-":
            return left - right, true

        case "/":
            if right == 0 {
                return 0, false
            }

            return left / right, true
        }

        return 0, false
    }

    return 0, false
}

// Resolve a marker expression written as text: a bare integer, `LIMITS.<field>`, or a
// top-level constant name.
bound_resolve :: proc(m: ^Model, expr: string) -> (value: int, ok: bool) {
    trimmed := strings.trim_space(expr)

    if trimmed == "" {
        return 0, false
    }

    if n, parsed := strconv.parse_int(trimmed); parsed {
        return n, true
    }

    if strings.has_prefix(trimmed, "LIMITS.") {
        found, has := m.limits[strings.trim_prefix(trimmed, "LIMITS.")]

        return found, has
    }

    found, has := m.consts[trimmed]

    return found, has
}
