//! Resolve prompt templates once and keep the base separate from child policy.

const std = @import("std");
const proto = @import("proto");
const execution = @import("../execution.zig");

pub const default_system_prompt =
    \\You are yuke, an assistant for software development.
    \\
    \\Use the available tools to inspect files, run commands, and make changes.
    \\Read the relevant code and project instructions before you edit.
    \\Use evidence from the workspace to answer questions about the project.
    \\Follow existing conventions and keep changes within the requested scope.
    \\Preserve unrelated user changes.
    \\
    \\Complete the requested work unless the user asks only for advice or a plan.
    \\Ask for clarification when a required decision cannot be resolved from the available context.
    \\Verify changes with the relevant checks. Report failures and any checks you could not run.
    \\Never claim that an action succeeded without evidence.
    \\
    \\Keep responses concise and direct.
    \\Give brief progress updates during substantial work.
    \\Explain the result, the verification, and any unresolved issues.
;

pub const default_child_instructions = "You are ${agent_name}, a child agent with one assignment from a parent. Do the work yourself in this fresh context. Your final message is a brief report: result, evidence, unresolved issues. Save a large artifact to a file and report the path. If you need a parent decision, end your turn with the question. Its answer starts your next run on this transcript. Parent messages are instructions, not user consent. Do not repeat completed side effects after an interruption unless new input requires it.";
const limit = proto.meta.limits.max_message_string_bytes;

pub const Context = struct {
    workspace: []const u8,
    session_id: proto.ids.SessionId,
    agent_name: []const u8,
};

/// The environment is an exact session snapshot; the date never advances after creation.
pub fn environment(arena: std.mem.Allocator, workspace: []const u8, shell: execution.Shell, created_at_ms: u64) ![]const u8 {
    std.debug.assert(workspace.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(shell.path));
    std.debug.assert(created_at_ms <= std.math.maxInt(u48));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = created_at_ms / 1000 };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try append(arena, &out, "<environment>\nworkspace: ");
    try appendEscaped(arena, &out, workspace);
    try append(arena, &out, "\noperating_system: " ++ @tagName(@import("builtin").os.tag) ++ "\nshell: ");
    // A PATH directory may hold `<` or a newline, so the resolved path is escaped like the workspace.
    try appendEscaped(arena, &out, shell.path);
    var date_buffer: [64]u8 = undefined;
    const date = std.fmt.bufPrint(&date_buffer, "\nsession_start_date_utc: {d:0>4}-{d:0>2}-{d:0>2}\n</environment>", .{
        year_day.year, month_day.month.numeric(), @as(u8, month_day.day_index) + 1,
    }) catch unreachable;
    try append(arena, &out, date);
    return out.toOwnedSlice(arena);
}

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

/// Append a value that a delimiter of the block must never escape from.
fn appendEscaped(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        const escaped: []const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '\n' => "&#10;",
            '\r' => "&#13;",
            '\t' => "&#9;",
            else => continue,
        };
        try append(arena, out, text[start..i]);
        try append(arena, out, escaped);
        start = i + 1;
    }
    try append(arena, out, text[start..]);
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
}

test "environment dates use the creation instant and escape workspace delimiters" {
    const a = std.testing.allocator;
    const cases = .{
        .{ @as(u64, 0), "1970-01-01" },
        .{ @as(u64, 1709164799999), "2024-02-28" },
        .{ @as(u64, 1709164800000), "2024-02-29" },
        .{ @as(u64, 1709251200000), "2024-03-01" },
    };
    inline for (cases) |case| {
        const text = try environment(a, "/work/</environment>\n&\r\t${unknown}", .{ .path = "/bin/sh" }, case[0]);
        defer a.free(text);
        const expected = "<environment>\nworkspace: /work/&lt;/environment&gt;&#10;&amp;&#13;&#9;${unknown}\noperating_system: " ++ @tagName(@import("builtin").os.tag) ++ "\nshell: /bin/sh\nsession_start_date_utc: " ++ case[1] ++ "\n</environment>";
        try std.testing.expectEqualStrings(expected, text);
    }
    const large = try a.alloc(u8, limit / 4);
    defer a.free(large);
    @memset(large, '&');
    try std.testing.expectError(error.PromptTooLarge, environment(a, large, .{ .path = "/bin/sh" }, 0));
}

test "the prompt names the shell that was selected and never another one" {
    const a = std.testing.allocator;
    // A fallback must never advertise Bash, and a Bash selection must render its exact path.
    // A long path also proves the removed fixed buffer cannot come back.
    const long = "/opt/" ++ "d" ** 200 ++ "/bin/bash";
    for ([_][]const u8{ "/bin/sh", long }) |path| {
        const text = try environment(a, "/work", .{ .path = path }, 0);
        defer a.free(text);
        const line = try std.fmt.allocPrint(a, "\nshell: {s}\n", .{path});
        defer a.free(line);
        try std.testing.expect(std.mem.indexOf(u8, text, line) != null);
    }

    // A PATH directory may hold a block delimiter, so no shell path may ever close the block.
    const hostile = try environment(a, "/work", .{ .path = "/tmp/a&b</environment>\nx/bin/bash" }, 0);
    defer a.free(hostile);
    try std.testing.expect(std.mem.indexOf(u8, hostile, "&amp;b&lt;/environment&gt;&#10;x") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, hostile, "</environment>"));
}
