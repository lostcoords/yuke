package js

import "core:mem"
import "core:slice"
import "core:strings"

// One unified-diff hunk. Deliberately not `wire.Diff_File`: the shared host does not depend
// on the protocol package, and this crosses into a script as a plain object either way.
Diff_Hunk :: struct {
    old_start: u64,
    old_lines: u64,
    new_start: u64,
    new_lines: u64,
    // Unified-diff body lines, each prefixed with a space, `-`, or `+`.
    lines:     []string,
}

Diff_File :: struct {
    path:  string,
    hunks: []Diff_Hunk,
}

// Equal lines kept around each change, as unified diff does.
@(private = "file")
DIFF_CONTEXT :: 3

// Myers costs O(ND) in time and its trace O(D^2) in space, so a rewrite with no common
// structure is refused rather than paid for. A diff that large is unreadable anyway.
@(private = "file")
DIFF_MAX_EDITS :: 512

// Hunks per file and lines per hunk. Matches the protocol's view-item bound, so a diff this
// package produces always fits the wire shape an embedder converts it to.
DIFF_MAX_ITEMS :: 1024

@(private = "file")
Diff_Op :: enum {
    Equal,
    Delete,
    Insert,
}

// One line of the edit script. The index the op does not name is -1.
@(private = "file")
Diff_Edit :: struct {
    op:  Diff_Op,
    old: int,
    new: int,
}

// Unified diff between two texts. `ok` is false when the
// change is too large to describe — the caller reports that rather than a truncated diff,
// which would read as a smaller change than the one that happened.
//
// Identical texts produce a file with no hunks. Every string is owned by `allocator`.
diff_text :: proc(
    path: string,
    before: string,
    after: string,
    allocator: mem.Allocator,
) -> (
    file: Diff_File,
    ok: bool,
) {
    assert(allocator.procedure != nil, "a diff needs an allocator")

    old_lines := diff_split(before, allocator)
    new_lines := diff_split(after, allocator)

    edits, scripted := diff_script(old_lines, new_lines, allocator)
    if !scripted do return {}, false

    hunks, built := diff_hunks(edits, old_lines, new_lines, allocator)
    if !built do return {}, false

    return Diff_File{path = strings.clone(path, allocator), hunks = hunks}, true
}

// Lines without their terminators. A trailing newline ends the last line rather than
// starting an empty one, so "a\n" and "a" split the same.
@(private = "file")
diff_split :: proc(text: string, allocator: mem.Allocator) -> []string {
    if text == "" do return nil

    body := text[:len(text) - 1] if text[len(text) - 1] == '\n' else text
    return strings.split(body, "\n", allocator)
}

// Myers' greedy algorithm with its trace, walked back into an edit script. Refuses past
// `DIFF_MAX_EDITS`, which is what bounds the trace.
@(private = "file")
diff_script :: proc(
    old_lines: []string,
    new_lines: []string,
    allocator: mem.Allocator,
) -> (
    edits: []Diff_Edit,
    ok: bool,
) {
    n := len(old_lines)
    m := len(new_lines)

    // A pure insert or delete needs no search, and it is the shape `write` always takes.
    if n == 0 || m == 0 {
        script := make([dynamic]Diff_Edit, 0, n + m, allocator)

        for index in 0 ..< n {
            append(&script, Diff_Edit{op = .Delete, old = index, new = -1})
        }

        for index in 0 ..< m {
            append(&script, Diff_Edit{op = .Insert, old = -1, new = index})
        }

        return script[:], true
    }

    max_d := min(n + m, DIFF_MAX_EDITS)
    offset := max_d
    width := 2 * max_d + 1

    v := make([]int, width, allocator)

    trace := make([dynamic][]int, 0, max_d + 1, allocator)

    v[offset + 1] = 0
    reached := -1

    search: for d in 0 ..= max_d {
        snapshot := slice.clone(v, allocator)

        append(&trace, snapshot)

        for k := -d; k <= d; k += 2 {
            x: int

            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                x = v[offset + k + 1]
            } else {
                x = v[offset + k - 1] + 1
            }

            y := x - k

            for x < n && y < m && old_lines[x] == new_lines[y] {
                x += 1
                y += 1
            }

            v[offset + k] = x

            if x >= n && y >= m {
                reached = d
                break search
            }
        }
    }

    if reached < 0 do return nil, false

    return diff_backtrack(trace[:], offset, n, m, allocator), true
}

// Walk the trace from the end, emitting the script in reverse and then flipping it.
@(private = "file")
diff_backtrack :: proc(trace: [][]int, offset: int, n: int, m: int, allocator: mem.Allocator) -> (edits: []Diff_Edit) {
    script := make([dynamic]Diff_Edit, 0, n + m, allocator)

    x := n
    y := m

    for d := len(trace) - 1; d > 0; d -= 1 {
        v := trace[d]
        k := x - y

        prev_k := k + 1 if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) else k - 1
        prev_x := v[offset + prev_k]
        prev_y := prev_x - prev_k

        for x > prev_x && y > prev_y {
            x -= 1
            y -= 1
            append(&script, Diff_Edit{op = .Equal, old = x, new = y})
        }

        if y > prev_y {
            y -= 1
            append(&script, Diff_Edit{op = .Insert, old = -1, new = y})
        } else {
            x -= 1
            append(&script, Diff_Edit{op = .Delete, old = x, new = -1})
        }
    }

    // Whatever is left is the leading snake, which is equal by construction.
    for x > 0 {
        x -= 1
        y -= 1
        append(&script, Diff_Edit{op = .Equal, old = x, new = y})
    }

    assert(x == 0 && y == 0, "a walked-back script consumes both texts")
    slice.reverse(script[:])

    return script[:]
}

// Group the script into hunks: every run of changes, padded with context and merged with
// the next run when they would otherwise overlap.
@(private = "file")
diff_hunks :: proc(
    edits: []Diff_Edit,
    old_lines: []string,
    new_lines: []string,
    allocator: mem.Allocator,
) -> (
    hunks: []Diff_Hunk,
    ok: bool,
) {
    out := make([dynamic]Diff_Hunk, 0, 8, allocator)

    index := 0
    for index < len(edits) {
        if edits[index].op == .Equal {
            index += 1

            continue
        }

        start := max(0, index - DIFF_CONTEXT)
        end := index

        // Extend while the next change is close enough that their context would touch.
        for end < len(edits) {
            if edits[end].op != .Equal {
                end += 1

                continue
            }

            gap := 0
            for end + gap < len(edits) && edits[end + gap].op == .Equal {
                gap += 1
            }

            if end + gap >= len(edits) || gap > 2 * DIFF_CONTEXT do break

            end += gap
        }

        end = min(len(edits), end + DIFF_CONTEXT)

        hunk, framed := diff_hunk_build(edits[start:end], old_lines, new_lines, allocator)
        if !framed do return nil, false

        if len(out) >= DIFF_MAX_ITEMS do return nil, false

        append(&out, hunk)
        index = end
    }

    return out[:], true
}

// One hunk over a contiguous slice of the script. Bodies carry the unified prefixes and no
// terminator, which is the shape `Diff_Hunk.lines` is decoded against.
@(private = "file")
diff_hunk_build :: proc(
    edits: []Diff_Edit,
    old_lines: []string,
    new_lines: []string,
    allocator: mem.Allocator,
) -> (
    hunk: Diff_Hunk,
    ok: bool,
) {
    assert(len(edits) > 0, "a hunk covers at least one edit")

    if len(edits) > DIFF_MAX_ITEMS do return {}, false

    body := make([]string, len(edits), allocator)

    old_start := -1
    new_start := -1
    old_count := 0
    new_count := 0

    for edit, index in edits {
        prefix: string
        text: string

        switch edit.op {
        case .Equal:
            prefix = " "
            text = old_lines[edit.old]

        case .Delete:
            prefix = "-"
            text = old_lines[edit.old]

        case .Insert:
            prefix = "+"
            text = new_lines[edit.new]
        }

        body[index] = strings.concatenate({prefix, text}, allocator)

        if edit.old >= 0 {
            old_start = edit.old if old_start < 0 else old_start
            old_count += 1
        }

        if edit.new >= 0 {
            new_start = edit.new if new_start < 0 else new_start
            new_count += 1
        }
    }

    // A hunk that only inserts names no old line, and the other way round. Unified diff
    // reports the position it would have occupied, which is 1-based like every other start.
    return Diff_Hunk {
            old_start = u64(old_start + 1) if old_start >= 0 else 1,
            old_lines = u64(old_count),
            new_start = u64(new_start + 1) if new_start >= 0 else 1,
            new_lines = u64(new_count),
            lines = body,
        },
        true
}
