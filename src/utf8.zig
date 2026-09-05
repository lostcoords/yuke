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

/// The widest UTF-8 character, so a walk back over `text` stops after this many bytes.
const max_char_bytes: usize = 4;

/// Return the length of `text` without a trailing character that its bytes do not complete.
pub fn whole(text: []const u8) usize {
    var i = text.len;
    var seen: usize = 0;
    while (i > 0 and seen < max_char_bytes) {
        i -= 1;
        seen += 1;
        if ((text[i] & 0xC0) == 0x80) continue;
        const need = std.unicode.utf8ByteSequenceLength(text[i]) catch return i;
        return if (need <= seen) text.len else i;
    }
    return text.len;
}

/// Return the largest length at or below `limit` that ends on a UTF-8 character boundary.
pub fn floor(text: []const u8, limit: usize) usize {
    return whole(text[0..@min(limit, text.len)]);
}

/// Return the count of leading bytes that continue a character cut off before `text`.
pub fn head(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and (text[i] & 0xC0) == 0x80) i += 1;
    return i;
}

const testing = std.testing;

test "floor never cuts a character in half" {
    try testing.expectEqual(@as(usize, 5), floor("hello", 64)); // shorter than the limit
    try testing.expectEqual(@as(usize, 3), floor("hello", 3)); // an ASCII cut is exact
    // "é" is two bytes, so a cut at 1 walks back to 0.
    try testing.expectEqual(@as(usize, 0), floor("é", 1));
    try testing.expectEqual(@as(usize, 2), floor("é", 2));
    // "aé" cuts back to 1 rather than splitting the second character.
    try testing.expectEqual(@as(usize, 1), floor("aé", 2));
    // A four-byte emoji walks back to the character start from every interior offset.
    try testing.expectEqual(@as(usize, 0), floor("😀", 1));
    try testing.expectEqual(@as(usize, 0), floor("😀", 3));
    try testing.expectEqual(@as(usize, 4), floor("😀", 4));
}

test "the head and the whole length trim a window to characters" {
    // A copied window has no bytes past its end, so the walk goes back to the last lead byte.
    try testing.expectEqual(@as(usize, 2), whole("ab\xF0\x9F\x99")); // three bytes of a four-byte character
    try testing.expectEqual(@as(usize, 6), whole("ab\u{1F642}")); // the character is whole
    try testing.expectEqual(@as(usize, 3), whole("abc"));
    try testing.expectEqual(@as(usize, 0), whole(""));
    try testing.expectEqual(@as(usize, 0), whole("\xF0")); // a lone lead byte completes nothing

    // A window can also open inside a character, and those bytes belong to the page before it.
    try testing.expectEqual(@as(usize, 3), head("\x9F\x99\x82ab")); // the tail of a four-byte character
    try testing.expectEqual(@as(usize, 0), head("ab"));
    try testing.expectEqual(@as(usize, 0), head(""));
}

test "a cut keeps a surrogate and drops a lead byte past the last codepoint" {
    try testing.expectEqual(@as(usize, 3), whole("\xed\xa0\x80")); // a surrogate is a whole three-byte sequence
    try testing.expectEqual(@as(usize, 2), whole("ok\xff")); // an invalid start byte goes with its tail
    try testing.expectEqual(@as(usize, 0), head("\xf5ok")); // a byte past U+10FFFF is no continuation
}
