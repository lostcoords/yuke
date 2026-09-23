//! Prompt sections and their canonical request text.

const std = @import("std");
const limit = @import("proto").meta.limits.max_message_string_bytes;

/// One prompt section as a `prompt.build` handler answers it and the store keeps it.
pub const Section = struct {
    key: []const u8,
    text: []const u8,
};

const max_key_bytes: usize = 64;

/// A key is 1 to 64 bytes and unique in its list. The check guards a hook answer, so it returns a bool.
pub fn valid(sections: []const Section) bool {
    for (sections, 0..) |section, i| {
        if (section.key.len == 0 or section.key.len > max_key_bytes) return false;
        for (sections[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, section.key)) return false;
    }
    return true;
}

/// Return one owned buffer; skip empty sections and separate the rest with two newline characters.
pub fn render(gpa: std.mem.Allocator, sections: []const Section) ![]u8 {
    var size: usize = 0;
    for (sections) |section| {
        if (section.text.len == 0) continue;
        if (size > 0) {
            if (limit - size < 2) return error.PromptTooLarge;
            size += 2;
        }
        if (section.text.len > limit - size) return error.PromptTooLarge;
        size += section.text.len;
    }
    std.debug.assert(size <= limit);
    const text = try gpa.alloc(u8, size);
    var offset: usize = 0;
    for (sections) |section| {
        if (section.text.len == 0) continue;
        if (offset > 0) {
            @memcpy(text[offset..][0..2], "\n\n");
            offset += 2;
        }
        @memcpy(text[offset..][0..section.text.len], section.text);
        offset += section.text.len;
    }
    std.debug.assert(offset == text.len);
    return text;
}

test "sections render in order, skip empty text, and keep their separators" {
    const cases = [_]struct { sections: []const Section, expected: []const u8 }{
        .{ .sections = &.{}, .expected = "" },
        .{ .sections = &.{ .{ .key = "a", .text = "" }, .{ .key = "b", .text = "env" } }, .expected = "env" },
        .{ .sections = &.{ .{ .key = "a", .text = "base" }, .{ .key = "b", .text = "env" } }, .expected = "base\n\nenv" },
        .{ .sections = &.{ .{ .key = "a", .text = "base\n\ntext" }, .{ .key = "b", .text = "child" }, .{ .key = "c", .text = "env" } }, .expected = "base\n\ntext\n\nchild\n\nenv" },
    };
    for (cases) |case| {
        const text = try render(std.testing.allocator, case.sections);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "a key is bounded and unique" {
    try std.testing.expect(valid(&.{ .{ .key = "a", .text = "" }, .{ .key = "b", .text = "" } }));
    try std.testing.expect(!valid(&.{.{ .key = "", .text = "" }}));
    try std.testing.expect(!valid(&.{.{ .key = "k" ** 65, .text = "" }}));
    try std.testing.expect(!valid(&.{ .{ .key = "a", .text = "" }, .{ .key = "a", .text = "x" } }));
}

test "prompt size includes every section and separator" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, limit + 1);
    defer a.free(large);
    @memset(large, 'x');
    const text = try render(a, &.{ .{ .key = "a", .text = large[0 .. limit - 6] }, .{ .key = "b", .text = "c" }, .{ .key = "c", .text = "e" } });
    defer a.free(text);
    try std.testing.expectEqual(limit, text.len);
    const cases = [_][]const Section{
        &.{.{ .key = "a", .text = large }},
        &.{ .{ .key = "a", .text = "" }, .{ .key = "b", .text = large } },
        &.{ .{ .key = "a", .text = large[0..limit] }, .{ .key = "b", .text = "e" } },
        &.{ .{ .key = "a", .text = large[0 .. limit - 5] }, .{ .key = "b", .text = "c" }, .{ .key = "c", .text = "e" } },
    };
    for (cases) |sections| try std.testing.expectError(error.PromptTooLarge, render(a, sections));
}
