//! The `write` built-in. Create a file or replace its whole content.

const std = @import("std");
const t = @import("tool.zig");
const h = @import("../host/host.zig");
const view = @import("view.zig");
const test_host = @import("../host/test_host.zig");

/// The tool reads old content up to this byte limit for the diff view. A larger file gets no view.
const max_diff_bytes = 10 * 1024 * 1024;

const Args = struct {
    path: t.schema.Str,
    content: t.schema.Str,
};

pub const tool = t.define(
    "write",
    "Create a file or replace its content. Pass the complete content.",
    Args,
    .{
        .path = .{ .description = "Pass the file path. A relative path resolves against the workspace root." },
        .content = .{ .description = "Pass the complete content for the file." },
    },
    execute,
);

fn execute(out: std.mem.Allocator, scratch: std.mem.Allocator, host: h.Host, args: Args) t.ToolError!t.ToolResult {
    const path = args.path.bytes;
    const content = args.content.bytes;
    // The view uses the old content only. The tool still writes a file that it cannot diff.
    const old: ?[]const u8 = host.readAll(scratch, path, max_diff_bytes) catch |err| switch (err) {
        error.NotFound => "", // A new file has an empty old side.
        error.TooLarge, error.InvalidUtf8 => null,
        else => |e| return e,
    };
    // Build the whole result BEFORE the write. A failure after the write would report an error for a
    // file that already changed, and the model would repeat the write.
    const rendered: view.Rendered = if (old) |text| try view.diffView(out, scratch, path, text, content) else .{};
    // A null view has no honest line count, because the daemon could not map the change.
    const text = if (rendered.views == null)
        try std.fmt.allocPrint(out, "The tool wrote {d} bytes.", .{content.len})
    else
        try std.fmt.allocPrint(out, "The tool wrote {d} bytes and changed {d} line(s).", .{ content.len, rendered.changed_lines });

    try host.writeFile(scratch, path, content);
    return .{ .text = text, .view = rendered.views };
}

const testing = std.testing;
const FileHost = test_host.FileHost;

test "write replaces a file and reports the changed lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .content = "one\ntwo\n" };
    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"a.txt\",\"content\":\"one\\ntwo changed\\n\"}");
    try testing.expectEqualStrings("one\ntwo changed\n", fake.written.?);
    try testing.expectEqualStrings("The tool wrote 16 bytes and changed 2 line(s).", res.text);
    try testing.expectEqualStrings("-two", res.view.?[0].diff.files[0].hunks[0].lines[1]);
}

test "write creates a new file with an empty old side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{}; // The host reports NotFound.
    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"new.txt\",\"content\":\"fresh\\n\"}");
    try testing.expectEqualStrings("fresh\n", fake.written.?);
    const hunk = res.view.?[0].diff.files[0].hunks[0];
    try testing.expectEqual(@as(u64, 0), hunk.old_lines);
}

test "write omits the view when the daemon cannot diff the old file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_]h.HostError{ error.TooLarge, error.InvalidUtf8 }) |err| {
        var fake: FileHost = .{ .read_error = err };
        const res = try tool.execute(a, a, fake.host(), "{\"path\":\"big.bin\",\"content\":\"x\"}");
        try testing.expectEqualStrings("x", fake.written.?); // The write still occurs.
        try testing.expect(res.view == null);
        try testing.expectEqualStrings("The tool wrote 1 bytes.", res.text);
    }
}

test "write returns the host error for a rejected path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .read_error = error.NotAFile };
    try testing.expectError(error.NotAFile, tool.execute(a, a, fake.host(), "{\"path\":\"dir\",\"content\":\"x\"}"));
    try testing.expect(fake.written == null); // A rejected path must not trigger a write.
}

test "write states no changed lines when the content matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .content = "same\n" };
    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"a.txt\",\"content\":\"same\\n\"}");
    try testing.expectEqualStrings("The tool wrote 5 bytes.", res.text);
    try testing.expect(res.view == null);
}
