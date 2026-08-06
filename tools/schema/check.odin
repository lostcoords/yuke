package schema

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "tools:gen"

// Compare declared `@bounded` markers against the bounds the validators read.
//
// Only procedures with `_validate` in the name are scanned — the package's convention for a
// validator or a validator helper, and `view_validate_slice` and `_validate_base64_inline`
// are where two of the bounds live. `@fixed` does not participate: `enforce_id` is generic
// over the array length, so no literal reaches the call site.
//
// The comparison is package-wide and set-level: it checks that each bound *expression* is
// both declared and enforced somewhere, not that a given marker pairs with a given check.
// Markers sharing an expression are therefore not individually verified. Per-field pairing
// is recoverable for the `enforce_bounded` sites that pass `self.<field>` or `v.<field>`,
// but not for those passing a local unwrapped from a `Maybe`.
check_bounds :: proc(m: ^Model, ps: ^Package_Source, d: ^gen.Diags) {
    assert(m != nil, "check_bounds needs a model")
    assert(ps != nil, "check_bounds needs a package source")

    declared := declared_bound_exprs(m)
    enforced := enforced_bound_exprs(ps)

    for expr, pos in enforced {
        if expr not_in declared {
            gen.diagf(d, pos, "validators enforce bound `%s` but no @bounded marker declares it", expr)
        }
    }

    for expr, pos in declared {
        if expr not_in enforced {
            gen.diagf(d, pos, "marker `@bounded %s` is declared but no validator enforces it", expr)
        }
    }
}

// Every `@bounded` expression declared by a field or alias, with one representative
// position for the diagnostic.
declared_bound_exprs :: proc(m: ^Model) -> map[string]gen.Pos {
    out: map[string]gen.Pos

    for s in m.structs {
        for f in s.fields {
            if f.bound.kind == .Bounded && f.bound.expr != "" && f.bound.expr not_in out {
                out[f.bound.expr] = f.pos
            }
        }
    }

    for a in m.aliases {
        if a.bound.kind == .Bounded && a.bound.expr != "" && a.bound.expr not_in out {
            out[a.bound.expr] = a.pos
        }
    }

    return out
}

// Every bound expression a validator reads: the first argument of `enforce_bounded`, and
// the right-hand side of a `len(…) > <bound>` collection cap. Both are matched as AST
// nodes, so `>=` is not a `>` and a bound inside a comment or string literal is not a bound.
enforced_bound_exprs :: proc(ps: ^Package_Source) -> map[string]gen.Pos {
    out: map[string]gen.Pos

    for name, ref in ps.procs {
        if !strings.contains(name, "_validate") {
            continue
        }

        for call in calls_in(ref.source, ref.body, {"enforce_bounded"}) {
            if len(call.args) == 0 {
                continue
            }

            record_bound(&out, call.args[0], source_pos(ref.source, ref.body.pos.line))
        }

        for cap in len_caps_in(ref.source, ref.body) {
            record_bound(&out, cap, source_pos(ref.source, ref.body.pos.line))
        }
    }

    return out
}

// Record a bound expression the first time it is seen. A nested call is a computed
// comparison rather than a declared bound, so it is skipped instead of recorded wrong.
record_bound :: proc(out: ^map[string]gen.Pos, expr: string, pos: gen.Pos) {
    trimmed := strings.trim_space(expr)

    if trimmed == "" || strings.contains(trimmed, "(") {
        return
    }

    if trimmed not_in out {
        out[trimmed] = pos
    }
}

// Verify every type the artifact names resolves to something it also defines. A dangling
// reference is not a protocol defect but it breaks any generator that walks the artifact, so
// it fails here rather than in someone else's build.
check_references :: proc(m: ^Model, d: ^gen.Diags) {
    assert(m != nil, "check_references needs a model")

    known: map[string]bool

    for s in m.structs {
        known[s.name] = true
    }

    for u in m.unions {
        known[u.name] = true
    }

    for e in m.enums {
        known[e.name] = true
    }

    for a in m.aliases {
        known[a.name] = true
    }

    for method in m.methods {
        check_reference(known, method.params_type, d, "method %s params", method.wire)
        check_reference(known, method.result_type, d, "method %s result", method.wire)
    }

    for b in m.broadcasts {
        check_reference(known, b.params_type, d, "broadcast %s params", b.wire)
    }

    for u in m.unions {
        for arm in u.arms {
            check_reference(known, arm.type, d, "union %s arm", u.name)
        }
    }

    for s in m.structs {
        for f in s.fields {
            check_reference(known, element_type(f.type_expr), d, "field %s.%s", s.name, f.name)
        }
    }
}

// Peel `Maybe(…)` and slice wrappers down to the named type, or "" for a scalar and for the
// fixed byte arrays that carry hex ids.
element_type :: proc(type_expr: string) -> string {
    out := type_expr

    for {
        if strings.has_prefix(out, "Maybe(") && strings.has_suffix(out, ")") {
            out = out[len("Maybe("):len(out) - 1]

            continue
        }

        if strings.has_prefix(out, "[]") {
            out = out[2:]

            continue
        }

        break
    }

    if strings.has_prefix(out, "[") {
        return ""
    }

    return slice.contains(SCALAR_BASES[:], out) ? "" : out
}

check_reference :: proc(known: map[string]bool, name: string, d: ^gen.Diags, format: string, args: ..any) {
    if name == "" || name in known {
        return
    }

    site := fmt.tprintf(format, ..args)
    gen.diagf(d, gen.Pos{}, "%s names `%s`, which the artifact does not define", site, name)
}

// Verify every `$ref` in the emitted schema document resolves to a definition it also carries. A
// dangling reference makes an eager validator refuse to compile the whole document, so it fails
// here rather than in a consumer's build.
check_schema_refs :: proc(root: json.Object, d: ^gen.Diags) {
    defs, has := root["$defs"].(json.Object)

    if !has {
        gen.diagf(d, gen.Pos{}, "the schema document has no $defs")

        return
    }

    refs: map[string]bool
    collect_refs(root, &refs)

    for name in refs {
        if name not_in defs {
            gen.diagf(d, gen.Pos{}, "the schema document references `#/$defs/%s`, which it does not define", name)
        }
    }
}

collect_refs :: proc(value: json.Value, out: ^map[string]bool) {
    #partial switch v in value {
    case json.Object:
        for key, inner in v {
            if key == "$ref" {
                if text, is_string := inner.(json.String); is_string {
                    out[strings.trim_prefix(text, "#/$defs/")] = true
                }

                continue
            }

            collect_refs(inner, out)
        }

    case json.Array:
        for inner in v {
            collect_refs(inner, out)
        }
    }
}
