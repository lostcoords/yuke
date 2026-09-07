//! Resolve prompt templates once and keep the base separate from child policy.

const std = @import("std");
const proto = @import("proto");

pub const default_child_instructions = "You are a child agent for one assignment. Use your own fresh context. Delegate only when a spawn tool is available. Child work has one shared tree limit. If a child is queued and you have no independent work, return your current result so its run can start. Child reports resume this session. Report your result, evidence, and unresolved issues to the parent. Never repeat completed side effects after an interruption unless new input requires it.";
const limit = proto.meta.limits.max_message_string_bytes;

pub const Context = struct {
    workspace: []const u8,
    session_id: proto.ids.SessionId,
    agent_name: []const u8,
};

pub fn expand(arena: std.mem.Allocator, template: []const u8, context: Context) ![]const u8 {
    std.debug.assert(context.workspace.len > 0);
    std.debug.assert(context.agent_name.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    const session_id = std.fmt.bytesToHex(context.session_id.raw, .lower);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, template, offset, "${")) |start| {
        try append(arena, &out, template[offset..start]);
        const end = std.mem.indexOfScalarPos(u8, template, start + 2, '}') orelse return error.InvalidPromptPlaceholder;
        const name = template[start + 2 .. end];
        const value = if (std.mem.eql(u8, name, "workspace")) context.workspace else if (std.mem.eql(u8, name, "session_id")) &session_id else if (std.mem.eql(u8, name, "agent_name")) context.agent_name else return error.InvalidPromptPlaceholder;
        try append(arena, &out, value);
        offset = end + 1;
    }
    try append(arena, &out, template[offset..]);
    return out.toOwnedSlice(arena);
}

/// The result can borrow either input; all slices must share the caller's lifetime.
pub fn compose(arena: std.mem.Allocator, base: ?[]const u8, child: ?[]const u8) !?[]const u8 {
    if (base) |text| if (text.len > limit) return error.PromptTooLarge;
    if (child) |text| if (text.len > limit) return error.PromptTooLarge;
    if (base == null or base.?.len == 0) return child orelse base;
    if (child == null or child.?.len == 0) return base;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try append(arena, &out, base.?);
    try append(arena, &out, "\n\n");
    try append(arena, &out, child.?);
    return try out.toOwnedSlice(arena);
}

fn append(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    std.debug.assert(out.items.len <= limit);
    if (text.len > limit - out.items.len) return error.PromptTooLarge;
    try out.appendSlice(arena, text);
    std.debug.assert(out.items.len <= limit);
}

test "prompt substitutions are literal and closed" {
    const a = std.testing.allocator;
    const ctx: Context = .{ .workspace = "/work/${unknown}", .session_id = .bytes(.{0} ** 16), .agent_name = "worker" };
    const text = try expand(a, "${workspace} ${agent_name} ${session_id}", ctx);
    defer a.free(text);
    try std.testing.expectEqualStrings("/work/${unknown} worker " ++ "0" ** 32, text);
    try std.testing.expectError(error.InvalidPromptPlaceholder, expand(a, "${unknown}", ctx));
    try std.testing.expectError(error.InvalidPromptPlaceholder, expand(a, "${workspace", ctx));
    const oversized = try a.alloc(u8, limit + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.PromptTooLarge, expand(a, oversized, ctx));
    try std.testing.expectError(error.PromptTooLarge, compose(a, oversized[0..limit], "x"));
}

test "prompt composition preserves null and empty values within the limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try compose(a, null, null) == null);
    try std.testing.expectEqualStrings("", (try compose(a, "", null)).?);
    try std.testing.expectEqualStrings("", (try compose(a, null, "")).?);
    try std.testing.expectEqualStrings("base", (try compose(a, "base", "")).?);
    try std.testing.expectEqualStrings("child", (try compose(a, "", "child")).?);
    try std.testing.expectEqualStrings("base\n\nchild", (try compose(a, "base", "child")).?);
    const text = try a.alloc(u8, limit + 1);
    @memset(text, 'x');
    try std.testing.expectEqual(limit, (try compose(a, text[0..limit], null)).?.len);
    try std.testing.expectError(error.PromptTooLarge, compose(a, text, null));
    try std.testing.expectError(error.PromptTooLarge, compose(a, null, text));
}
