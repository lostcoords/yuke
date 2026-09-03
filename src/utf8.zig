//! Make arbitrary bytes safe for a transcript, a JSON string, and a JavaScript string.
//! A command prints any bytes, but every consumer above this line reads text.

const std = @import("std");

/// U+FFFD stands for one byte the decoder cannot read.
const replacement = &std.unicode.replacement_character_utf8;

/// Append `raw` to `buf`. Keep every valid codepoint and replace each other byte with U+FFFD.
pub fn appendSanitized(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < raw.len) {
        const need = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            try buf.appendSlice(gpa, replacement);
            i += 1;
            continue;
        };
        if (raw.len - i < need or !std.unicode.utf8ValidateSlice(raw[i..][0..need])) {
            try buf.appendSlice(gpa, replacement);
            i += 1;
            continue;
        }
        try buf.appendSlice(gpa, raw[i..][0..need]);
        i += need;
    }
}

/// Answer a valid UTF-8 copy of `raw`. The caller owns the result.
pub fn sanitize(gpa: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try appendSanitized(gpa, &buf, raw);
    return buf.toOwnedSlice(gpa);
}

const testing = std.testing;

test "sanitize keeps every valid codepoint" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("", try sanitize(a, ""));
    try testing.expectEqualStrings("plain", try sanitize(a, "plain"));
    try testing.expectEqualStrings("\u{65b0}\u{520a}", try sanitize(a, "\u{65b0}\u{520a}"));
    try testing.expectEqualStrings("\u{1f600}", try sanitize(a, "\u{1f600}"));
}

// Every shape the decoder refuses becomes one replacement for each byte it cannot read.
test "sanitize replaces every kind of invalid sequence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = "\xc0\xaf", .want = "\u{FFFD}\u{FFFD}" }, // an overlong slash
        .{ .raw = "\x80", .want = "\u{FFFD}" }, // a lone continuation byte
        .{ .raw = "\xc1", .want = "\u{FFFD}" }, // a lead byte no codepoint uses
        .{ .raw = "\xf5\x80\x80\x80", .want = "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" }, // past U+10FFFF
        .{ .raw = "\xed\xa0\x80", .want = "\u{FFFD}\u{FFFD}\u{FFFD}" }, // a surrogate
        .{ .raw = "\xff\xfe", .want = "\u{FFFD}\u{FFFD}" }, // bytes UTF-8 never uses
        .{ .raw = "a\xe6", .want = "a\u{FFFD}" }, // a sequence cut at the end
        .{ .raw = "ok\xe6\x96", .want = "ok\u{FFFD}\u{FFFD}" }, // a three-byte codepoint cut short
        .{ .raw = "\u{65b0}\u{520a}\xff!", .want = "\u{65b0}\u{520a}\u{FFFD}!" }, // a stray byte beside text
    };
    for (cases) |case| {
        const got = try sanitize(a, case.raw);
        try testing.expectEqualStrings(case.want, got);
        try testing.expect(std.unicode.utf8ValidateSlice(got));
    }
}
