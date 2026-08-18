package js

import "core:fmt"
import "core:strings"
import "core:testing"


// Every hunk body line, joined, so a test reads like the diff it expects.
@(private = "file")
diff_body :: proc(t: ^testing.T, file: Diff_File) -> string {
    out: strings.Builder
    strings.builder_init(&out, context.temp_allocator)

    for hunk, index in file.hunks {
        if index > 0 do strings.write_string(&out, "@@\n")

        for line in hunk.lines {
            strings.write_string(&out, line)
            strings.write_byte(&out, '\n')
        }
    }

    return strings.to_string(out)
}

@(test)
test_diff_reports_no_hunks_for_identical_text :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    file, ok := diff_text("a.txt", "one\ntwo\n", "one\ntwo\n", context.temp_allocator)
    testing.expect(t, ok, "identical text diffs")
    testing.expect_value(t, len(file.hunks), 0)
    testing.expect_value(t, file.path, "a.txt")

    // A trailing newline ends the last line rather than starting an empty one.
    same, same_ok := diff_text("a.txt", "one\ntwo", "one\ntwo\n", context.temp_allocator)
    testing.expect(t, same_ok, "a trailing newline diffs")
    testing.expect_value(t, len(same.hunks), 0)
}

@(test)
test_diff_writes_a_new_file_as_pure_insertion :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    file, ok := diff_text("new.txt", "", "one\ntwo\n", context.temp_allocator)
    testing.expect(t, ok, "a new file diffs")

    if !testing.expect_value(t, len(file.hunks), 1) do return

    hunk := file.hunks[0]
    testing.expect_value(t, hunk.old_lines, u64(0))
    testing.expect_value(t, hunk.new_start, u64(1))
    testing.expect_value(t, hunk.new_lines, u64(2))
    testing.expect_value(t, diff_body(t, file), "+one\n+two\n")
}

@(test)
test_diff_reports_a_deletion_and_a_replacement :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    emptied, ok := diff_text("a.txt", "one\ntwo\n", "", context.temp_allocator)
    testing.expect(t, ok, "an emptied file diffs")
    testing.expect_value(t, diff_body(t, emptied), "-one\n-two\n")

    if testing.expect_value(t, len(emptied.hunks), 1) {
        testing.expect_value(t, emptied.hunks[0].old_start, u64(1))
        testing.expect_value(t, emptied.hunks[0].old_lines, u64(2))
        testing.expect_value(t, emptied.hunks[0].new_lines, u64(0))
    }

    // A replaced middle line keeps its neighbours as context, delete before insert.
    changed, changed_ok := diff_text("a.txt", "one\ntwo\nthree\n", "one\n2\nthree\n", context.temp_allocator)
    testing.expect(t, changed_ok, "a replacement diffs")
    testing.expect_value(t, diff_body(t, changed), " one\n-two\n+2\n three\n")

    if testing.expect_value(t, len(changed.hunks), 1) {
        hunk := changed.hunks[0]
        testing.expect_value(t, hunk.old_start, u64(1))
        testing.expect_value(t, hunk.old_lines, u64(3))
        testing.expect_value(t, hunk.new_start, u64(1))
        testing.expect_value(t, hunk.new_lines, u64(3))
    }
}

@(test)
test_diff_splits_distant_changes_into_separate_hunks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    before: strings.Builder
    after: strings.Builder
    strings.builder_init(&before, context.temp_allocator)
    strings.builder_init(&after, context.temp_allocator)

    // Twenty lines apart is well past twice the context, so the two edits cannot merge.
    for index in 0 ..< 40 {
        line := fmt.tprintf("line %d\n", index)
        strings.write_string(&before, line)
        strings.write_string(&after, "changed\n" if index == 0 || index == 30 else line)
    }

    file, ok := diff_text("a.txt", strings.to_string(before), strings.to_string(after), context.temp_allocator)
    testing.expect(t, ok, "a two-change file diffs")
    testing.expect_value(t, len(file.hunks), 2)

    if len(file.hunks) == 2 {
        // Each hunk carries its change plus context, never the 30 lines between them.
        testing.expect_value(t, file.hunks[0].old_start, u64(1))
        testing.expect(t, file.hunks[0].old_lines <= 4, "the first hunk stops after its context")
        testing.expect_value(t, file.hunks[1].old_start, u64(28))
        testing.expect_value(t, file.hunks[1].old_lines, u64(7))
    }

    // Adjacent changes merge instead, because their context would overlap.
    near: strings.Builder
    strings.builder_init(&near, context.temp_allocator)
    for index in 0 ..< 40 {
        strings.write_string(&near, "changed\n" if index == 0 || index == 3 else fmt.tprintf("line %d\n", index))
    }

    merged, merged_ok := diff_text("a.txt", strings.to_string(before), strings.to_string(near), context.temp_allocator)
    testing.expect(t, merged_ok, "an adjacent-change file diffs")
    testing.expect_value(t, len(merged.hunks), 1)
}

@(test)
test_diff_refuses_a_change_too_large_to_describe :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // No line in common, so the edit distance is the whole of both texts — past the bound
    // that keeps the trace affordable. A truncated diff would read as a smaller change.
    before: strings.Builder
    after: strings.Builder
    strings.builder_init(&before, context.temp_allocator)
    strings.builder_init(&after, context.temp_allocator)

    for index in 0 ..< 600 {
        strings.write_string(&before, fmt.tprintf("old %d\n", index))
        strings.write_string(&after, fmt.tprintf("new %d\n", index))
    }

    _, ok := diff_text("a.txt", strings.to_string(before), strings.to_string(after), context.temp_allocator)
    testing.expect(t, !ok, "a diff past the edit bound is refused, not truncated")
}
