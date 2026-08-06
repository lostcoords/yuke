package gen

import "core:os"
import "core:slice"
import "core:strings"

// Write `data` to `path`, or under `--check` verify the committed copy is what this run
// produces. Drift names the first differing line: both artifacts are far too large for
// "stale" to be a useful thing to hand someone.
emit :: proc(data: []byte, path: string, check: bool, d: ^Diags) {
    assert(len(data) > 0, "emit needs encoded bytes")

    if !check {
        if err := os.write_entire_file(path, data); err != nil {
            diagf(d, Pos{file = path}, "cannot write the artifact")
        }

        return
    }

    existing, err := os.read_entire_file_from_path(path, context.allocator)

    if err != nil {
        diagf(d, Pos{file = path}, "nothing committed to check against; regenerate and commit it")

        return
    }

    if slice.equal(existing, data) {
        return
    }

    diagf(d, Pos{file = path}, "the committed artifact is stale; regenerate and commit the result")
    report_first_difference(existing, data, path, d)
}

// Point at the first differing line, so a stale artifact says what moved.
@(private = "file")
report_first_difference :: proc(old_data, new_data: []byte, path: string, d: ^Diags) {
    old_lines := strings.split_lines(string(old_data), context.temp_allocator)
    new_lines := strings.split_lines(string(new_data), context.temp_allocator)

    for i in 0 ..< min(len(old_lines), len(new_lines)) {
        if old_lines[i] == new_lines[i] {
            continue
        }

        diagf(d, Pos{file = path, line = i + 1}, "committed: %s", strings.trim_space(old_lines[i]))
        diagf(d, Pos{file = path, line = i + 1}, "generated: %s", strings.trim_space(new_lines[i]))

        return
    }

    diagf(d, Pos{file = path}, "committed has %d lines, generated has %d", len(old_lines), len(new_lines))
}
