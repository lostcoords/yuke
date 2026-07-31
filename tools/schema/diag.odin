package schema

import "core:fmt"

Diag :: struct {
    pos: Pos,
    msg: string,
}

Diags :: struct {
    list: [dynamic]Diag,
}

// Record a failure at `pos`.
diagf :: proc(d: ^Diags, pos: Pos, format: string, args: ..any) {
    assert(d != nil, "diagf needs a sink")
    append(&d.list, Diag{pos = pos, msg = fmt.aprintf(format, ..args)})
}

// Whether anything was recorded.
diags_failed :: proc(d: ^Diags) -> bool {
    assert(d != nil, "diags_failed needs a sink")

    return len(d.list) > 0
}

// Print every diagnostic in `file:line: message` form so an editor can jump to it.
diags_report :: proc(d: ^Diags) {
    assert(d != nil, "diags_report needs a sink")

    for entry in d.list {
        if entry.pos.line > 0 {
            fmt.eprintfln("%s:%d: %s", entry.pos.file, entry.pos.line, entry.msg)
        } else if entry.pos.file != "" {
            fmt.eprintfln("%s: %s", entry.pos.file, entry.msg)
        } else {
            fmt.eprintfln("%s", entry.msg)
        }
    }

    fmt.eprintln()
    fmt.eprintfln("%d problem(s); no artifact written.", len(d.list))
}
