//! The `exec` built-in. Run one shell command and return its output.

const std = @import("std");
const t = @import("tool.zig");

/// The command deadline. `plan.md` fixes both values.
const default_timeout_ms: u32 = 120_000;
const max_timeout_ms: u32 = 600_000;

/// The cap for each stream. A command that prints more loses the tail, not the whole result.
const max_stream_bytes: u32 = 64 * 1024;

const Args = struct {
    command: t.schema.Str,
    cwd: ?t.schema.Str = null,
    timeout_ms: ?u32 = null,
};

pub const tool = t.define(
    "exec",
    "Run one shell command with /bin/sh and return its output. Each call starts a new shell, so a " ++
        "directory change or a variable does not carry to the next call. Stdin is closed, so a command " ++
        "must not wait for input. The tool returns the head and the tail of a long stream.",
    Args,
    .{
        .command = .{ .description = "Pass the shell command to run." },
        .cwd = .{ .description = "Pass the working directory. A relative path resolves against the workspace root." },
        .timeout_ms = .{
            .description = "Pass the timeout in milliseconds. The default is 120000 and the maximum is 600000.",
            .minimum = 1,
            .maximum = max_timeout_ms,
        },
    },
    execute,
);

fn execute(out: std.mem.Allocator, scratch: std.mem.Allocator, host: t.ToolHost, args: Args) t.ToolError!t.ToolResult {
    // A blank command exits 0 and would tell the model that it finished work.
    if (std.mem.trim(u8, args.command.bytes, " \t\r\n").len == 0) return error.InvalidArg;
    const timeout_ms = args.timeout_ms orelse default_timeout_ms;
    if (timeout_ms == 0 or timeout_ms > max_timeout_ms) return error.InvalidArg;
    const result = try host.exec(scratch, .{
        .command = args.command.bytes,
        .cwd = if (args.cwd) |c| c.bytes else null,
        .timeout_ms = timeout_ms,
        .max_stream_bytes = max_stream_bytes,
    });
    return .{ .text = try render(out, result, timeout_ms) };
}

/// Build the model-visible text: the output, then the errors, then the outcome.
/// A command can print these same markers, so the model must not treat them as proof. The wire has
/// no structured field for a tool result today; see docs/plan.md.
fn render(out: std.mem.Allocator, r: t.ExecResult, timeout_ms: u32) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(out, r.stdout);
    if (r.stderr.len != 0) {
        try endLine(out, &buf);
        try buf.print(out, "[stderr]\n{s}", .{r.stderr});
    }
    const empty = buf.items.len == 0;
    try endLine(out, &buf);
    if (empty) try buf.appendSlice(out, "[no output]\n");
    switch (r.outcome) {
        .timed_out => try buf.print(
            out,
            "[The command passed its {d} ms timeout. The tool stopped the process group. " ++
                "Run a smaller command, or raise timeout_ms up to {d}.]",
            .{ timeout_ms, max_timeout_ms },
        ),
        .signaled => |sig| try buf.print(out, "[A signal ended the command: {d}.]", .{sig}),
        .exited => |code| try buf.print(out, "[exit code: {d}]", .{code}),
    }
    return buf.toOwnedSlice(out);
}

/// Start a new line unless the text already ends with one, or holds nothing.
fn endLine(out: std.mem.Allocator, buf: *std.ArrayList(u8)) error{OutOfMemory}!void {
    if (buf.items.len == 0 or buf.items[buf.items.len - 1] == '\n') return;
    try buf.append(out, '\n');
}

const testing = std.testing;
const FakeHost = @import("test_host.zig").ExecHost;

test "exec reports the output and the exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .stdout = "hello\n", .stderr = "", .outcome = .{ .exited = 0 } } };
    const res = try tool.execute(a, a, fake.host(), "{\"command\":\"echo hello\"}");
    try testing.expectEqualStrings("hello\n[exit code: 0]", res.text);
    try testing.expectEqual(default_timeout_ms, fake.seen.?.timeout_ms);
    try testing.expectEqual(@as(?[]const u8, null), fake.seen.?.cwd);
}

test "exec places stderr after stdout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .stdout = "out\n", .stderr = "bad\n", .outcome = .{ .exited = 2 } } };
    const res = try tool.execute(a, a, fake.host(), "{\"command\":\"x\"}");
    try testing.expectEqualStrings("out\n[stderr]\nbad\n[exit code: 2]", res.text);
}

test "exec states a deadline and a signal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var slow: FakeHost = .{ .result = .{ .stdout = "", .stderr = "", .outcome = .timed_out } };
    const timed = try tool.execute(a, a, slow.host(), "{\"command\":\"sleep 999\",\"timeout_ms\":50}");
    try testing.expect(std.mem.indexOf(u8, timed.text, "passed its 50 ms timeout") != null);
    try testing.expect(std.mem.indexOf(u8, timed.text, "raise timeout_ms") != null);
    try testing.expectEqual(@as(u32, 50), slow.seen.?.timeout_ms);

    var killed: FakeHost = .{ .result = .{ .stdout = "", .stderr = "", .outcome = .{ .signaled = 9 } } };
    const res = try tool.execute(a, a, killed.host(), "{\"command\":\"x\"}");
    try testing.expectEqualStrings("[no output]\n[A signal ended the command: 9.]", res.text);
}

test "exec ends every section on its own line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Output without a final newline must not run into the outcome line.
    var bare: FakeHost = .{ .result = .{ .stdout = "abc", .stderr = "", .outcome = .{ .exited = 0 } } };
    const res = try tool.execute(a, a, bare.host(), "{\"command\":\"x\"}");
    try testing.expectEqualStrings("abc\n[exit code: 0]", res.text);

    // A stderr that already ends with a newline must not gain a blank line.
    var both: FakeHost = .{ .result = .{ .stdout = "o\n", .stderr = "e\n", .outcome = .{ .exited = 1 } } };
    const pair = try tool.execute(a, a, both.host(), "{\"command\":\"x\"}");
    try testing.expectEqualStrings("o\n[stderr]\ne\n[exit code: 1]", pair.text);
}

test "exec states an empty result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .stdout = "", .stderr = "", .outcome = .{ .exited = 0 } } };
    const res = try tool.execute(a, a, fake.host(), "{\"command\":\"true\"}");
    try testing.expectEqualStrings("[no output]\n[exit code: 0]", res.text);
}

test "exec rejects a blank command and an invalid timeout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakeHost = .{ .result = .{ .stdout = "", .stderr = "", .outcome = .{ .exited = 0 } } };
    const h = fake.host();
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"command\":\"x\",\"timeout_ms\":600001}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"command\":\"x\",\"timeout_ms\":0}"));
    try testing.expectError(error.InvalidArg, tool.execute(a, a, h, "{\"command\":\"   \"}"));
}
