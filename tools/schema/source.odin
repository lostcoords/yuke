package schema

import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// One parsed file plus the doc index built over it.
Source :: struct {
    path:     string,
    file:     ast.File,

    // Doc text keyed by the line the comment group ends on. An enum member's doc is the
    // group ending on the line above it.
    doc_ends: map[int]string,
}

// A procedure body together with the file it was parsed from. The two travel as one
// because a body's node offsets are only meaningful against its own source; keeping them
// apart let a caller slice the wrong file and silently get "".
Proc_Ref :: struct {
    body:        ^ast.Stmt,
    source:      ^Source,

    // First named result's type, as source text. For `*_from_reader` and the private
    // `_*_body` helpers this is the payload type, which is how a dispatch case naming a
    // procedure resolves to a type.
    result_type: string,
}

// Every parsed non-test file of the wire package, in path order.
Package_Source :: struct {
    files: [dynamic]Source,
    procs: map[string]Proc_Ref,
}

// Parse every `.odin` file in `dir`, skipping `_test.odin`: test files hold no protocol
// declarations, and parsing them would put fixtures into the model.
package_load :: proc(dir: string, d: ^Diags, allocator := context.allocator) -> (out: Package_Source, ok: bool) {
    assert(d != nil, "package_load needs a diagnostic sink")

    infos, dir_err := os.read_directory_by_path(dir, -1, allocator)

    if dir_err != nil {
        diagf(d, Pos{file = dir}, "cannot read the wire package directory")

        return {}, false
    }

    paths := make([dynamic]string, 0, len(infos), allocator)

    for info in infos {
        if info.type != .Regular || !strings.has_suffix(info.name, ".odin") {
            continue
        }

        if strings.has_suffix(info.name, "_test.odin") {
            continue
        }

        joined, join_err := filepath.join({dir, info.name}, allocator)

        if join_err != nil {
            diagf(d, Pos{file = dir}, "cannot build a path for %s", info.name)

            continue
        }

        append(&paths, joined)
    }

    slice.sort(paths[:])
    // Sized up front: `Proc_Ref` holds a `^Source` into this array, so it must not move.
    out.files = make([dynamic]Source, 0, len(paths), allocator)

    for path in paths {
        src, read_err := os.read_entire_file_from_path(path, allocator)

        if read_err != nil {
            diagf(d, Pos{file = path}, "cannot read source file")

            continue
        }

        s := Source {
            path = path,
            file = ast.File{fullpath = path, src = string(src)},
        }
        p := parser.default_parser()

        if !parser.parse_file(&p, &s.file) {
            diagf(d, Pos{file = path}, "the parser rejected this file")

            continue
        }

        source_index_comments(&s)
        append(&out.files, s)
    }

    if len(out.files) == 0 {
        diagf(d, Pos{file = dir}, "the wire package has no parsable source files")

        return out, false
    }

    assert(len(out.files) <= cap(out.files), "the file array never reallocates")
    package_index_procs(&out)

    return out, !diags_failed(d)
}

// Build the end-line -> doc-text index. `parse_file` collects every comment group in
// `file.comments`, which is the only route to an enum member's documentation.
source_index_comments :: proc(s: ^Source) {
    assert(s != nil, "source_index_comments needs a source")

    for group in s.file.comments {
        if len(group.list) == 0 {
            continue
        }

        s.doc_ends[group.list[len(group.list) - 1].pos.line] = comment_text(group)
    }
}

// Index every top-level procedure with its owning file and result type. The dispatch
// switches identify payloads by procedure, so this is what turns
// `session_result_from_reader` back into `Session_Result`.
package_index_procs :: proc(ps: ^Package_Source) {
    assert(ps != nil, "package_index_procs needs a package source")

    for &s in ps.files {
        for decl in s.file.decls {
            v, is_single := decl_single(decl)

            if !is_single || v.is_mutable {
                continue
            }

            lit, is_proc := v.values[0].derived.(^ast.Proc_Lit)

            if !is_proc || lit.body == nil {
                continue
            }

            name := expr_text(&s, v.names[0])
            ps.procs[name] = Proc_Ref {
                body        = lit.body,
                source      = &s,
                result_type = proc_first_result_type(&s, lit),
            }
        }
    }
}

// The first named result's type of a procedure literal, as source text. A `*_from_reader`
// returns `(value: T, err: Validation_Error)`, so this is T.
proc_first_result_type :: proc(s: ^Source, lit: ^ast.Proc_Lit) -> string {
    assert(lit != nil, "proc_first_result_type needs a procedure literal")

    if lit.type == nil || lit.type.results == nil || len(lit.type.results.list) == 0 {
        return ""
    }

    return expr_text(s, lit.type.results.list[0].type)
}

// Source slice for any expression. The model records type expressions verbatim rather
// than resolving them, so it keeps what the author wrote.
expr_text :: proc(s: ^Source, e: ^ast.Expr) -> string {
    if s == nil || e == nil {
        return ""
    }

    return node_text(s.file.src, e)
}

// The individual `//` lines of a doc comment group. Markers are matched per line so a
// bound written inside a prose sentence is not mistaken for a declaration.
comment_lines :: proc(g: ^ast.Comment_Group, allocator := context.allocator) -> []string {
    if g == nil {
        return nil
    }

    out := make([dynamic]string, 0, len(g.list), allocator)

    for tok in g.list {
        append(&out, strings.trim_space(strings.trim_prefix(tok.text, "//")))
    }

    return out[:]
}

// A doc comment group as one line of prose.
comment_text :: proc(g: ^ast.Comment_Group) -> string {
    if g == nil {
        return ""
    }

    return strings.join(comment_lines(g, context.temp_allocator), " ")
}

// A line within `s`, for diagnostics.
source_pos :: proc(s: ^Source, line: int) -> Pos {
    assert(s != nil, "source_pos needs a source")

    return Pos{file = s.path, line = line}
}
