package gen

import "core:fmt"
import "core:strings"

// Where a diagnostic points, for a human to act on.
Pos :: struct {
    // Path as given on the command line.
    file: string,

    // 1-based line, or 0 if the diagnostic isn't line-specific.
    line: int,
}

Diag :: struct {
    pos: Pos,
    msg: string,
}

Diags :: struct {
    list: [dynamic]Diag,
}

// Record a failure at `pos`. `pos.file` is cloned, so a caller may free the
// string it passed the moment this returns — the sink outlives any one path.
diagf :: proc(d: ^Diags, pos: Pos, format: string, args: ..any) {
    assert(d != nil, "diagf needs a sink")

    owned := pos
    owned.file = strings.clone(pos.file)

    append(&d.list, Diag{pos = owned, msg = fmt.aprintf(format, ..args)})
}

// Whether anything was recorded.
diags_failed :: proc(d: ^Diags) -> bool {
    assert(d != nil, "diags_failed needs a sink")

    return len(d.list) > 0
}

// Release every recorded message and blank the sink.
diags_destroy :: proc(d: ^Diags) {
    assert(d != nil, "diags_destroy needs a sink")

    for entry in d.list {
        delete(entry.pos.file)
        delete(entry.msg)
    }

    delete(d.list)
    d^ = {}
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
