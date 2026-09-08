//! Exact prompt components and their canonical request text.

const std = @import("std");
const limit = @import("proto").meta.limits.max_message_string_bytes;

pub const Parts = struct {
    base: []const u8,
    instructions: []const u8 = "",
    child_policy: ?[]const u8,
    environment: []const u8,

    /// Return one owned buffer; skip empty parts and separate the rest with two newline characters.
    pub fn render(self: Parts, gpa: std.mem.Allocator) ![]u8 {
        const parts = [_][]const u8{ self.base, self.instructions, self.child_policy orelse "", self.environment };
        var size: usize = 0;
        for (parts) |part| {
            if (part.len == 0) continue;
            if (size > 0) {
                if (limit - size < 2) return error.PromptTooLarge;
                size += 2;
            }
            if (part.len > limit - size) return error.PromptTooLarge;
            size += part.len;
        }
        std.debug.assert(size <= limit);
        const text = try gpa.alloc(u8, size);
        var offset: usize = 0;
        for (parts) |part| {
            if (part.len == 0) continue;
            if (offset > 0) {
                @memcpy(text[offset..][0..2], "\n\n");
                offset += 2;
            }
            @memcpy(text[offset..][0..part.len], part);
            offset += part.len;
        }
        std.debug.assert(offset == text.len);
        return text;
    }
};

test "prompt parts preserve text and omit empty components" {
    const cases = [_]struct { parts: Parts, expected: []const u8 }{
        .{ .parts = .{ .base = "", .child_policy = null, .environment = "" }, .expected = "" },
        .{ .parts = .{ .base = "", .child_policy = "", .environment = "env" }, .expected = "env" },
        .{ .parts = .{ .base = "base", .child_policy = null, .environment = "env" }, .expected = "base\n\nenv" },
        .{ .parts = .{ .base = "", .child_policy = "child", .environment = "env" }, .expected = "child\n\nenv" },
        .{ .parts = .{ .base = "base", .instructions = "rules", .child_policy = "child", .environment = "env" }, .expected = "base\n\nrules\n\nchild\n\nenv" },
        .{ .parts = .{ .base = "base\n\ntext", .child_policy = "child", .environment = "env" }, .expected = "base\n\ntext\n\nchild\n\nenv" },
    };
    for (cases) |case| {
        const text = try case.parts.render(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "prompt size includes every component and separator" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, limit + 1);
    defer a.free(large);
    @memset(large, 'x');
    const exact: Parts = .{ .base = large[0 .. limit - 6], .child_policy = "c", .environment = "e" };
    const text = try exact.render(a);
    defer a.free(text);
    try std.testing.expectEqual(limit, text.len);
    const cases = [_]Parts{
        .{ .base = large, .child_policy = null, .environment = "" },
        .{ .base = "", .instructions = large, .child_policy = null, .environment = "" },
        .{ .base = "", .child_policy = large, .environment = "" },
        .{ .base = "", .child_policy = null, .environment = large },
        .{ .base = large[0..limit], .child_policy = null, .environment = "e" },
        .{ .base = large[0 .. limit - 5], .child_policy = "c", .environment = "e" },
    };
    for (cases) |parts| try std.testing.expectError(error.PromptTooLarge, parts.render(a));
}
