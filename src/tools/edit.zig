//! The `edit` built-in. Replace an exact string in a file.

const std = @import("std");
const t = @import("tool.zig");
const h = @import("../host/host.zig");
const view = @import("view.zig");
const test_host = @import("../host/test_host.zig");

/// The largest file the tool reads. An edit rewrites the whole file. The read must hold every byte.
const max_file_bytes = 10 * 1024 * 1024;

const Args = struct {
    path: t.schema.Str,
    old_string: t.schema.Str,
    new_string: t.schema.Str,
    replace_all: bool = false,
};

pub const tool = t.define(
    "edit",
    "Replace an exact string in a file. old_string must appear exactly once unless replace_all is true. " ++
        "Matches never overlap. Copy old_string from the file. Never include the prefix that read adds.",
    Args,
    .{
        .path = .{ .description = "The file path. A relative path resolves against the workspace root." },
        .old_string = .{ .description = "The exact text to replace. It must match the file byte for byte." },
        .new_string = .{ .description = "The replacement text." },
        .replace_all = .{ .description = "Replace every match instead of one match. Matches never overlap." },
    },
    execute,
);

fn execute(out: std.mem.Allocator, scratch: std.mem.Allocator, host: h.Host, args: Args) t.ToolError!t.ToolResult {
    const path = args.path.bytes;
    const old_string = args.old_string.bytes;
    const new_string = args.new_string.bytes;
    // `std.mem.count` asserts a non-empty needle. An empty old_string is peer input, so reject it here.
    if (old_string.len == 0) return error.InvalidArg;
    if (std.mem.eql(u8, old_string, new_string)) return error.NoChange;

    // Every read error stops the edit. An edit rewrites the whole file, so it needs every byte.
    const old = try host.readAll(scratch, path, max_file_bytes);
    const matches = std.mem.count(u8, old, old_string);
    if (matches == 0) return error.NoMatch;
    if (matches > 1 and !args.replace_all) return error.Ambiguous;

    // Measure the result before the allocation. A wide `replace_all` grows the file by a multiple.
    const removed = matches * old_string.len;
    std.debug.assert(removed <= old.len); // matches never overlap, so they fit in the old text
    const grown = (old.len - removed) +| (matches *| new_string.len); // saturate; the cap rejects it
    if (grown > max_file_bytes) return error.TooLarge;

    // One match without `replace_all` gives the same bytes, so one call covers both cases.
    const new = try std.mem.replaceOwned(u8, scratch, old, old_string, new_string);
    // Build the whole result BEFORE the write. A failure after the write would report an error for a
    // file that already changed, and the model would repeat the edit.
    const rendered = try view.diffView(out, scratch, path, old, new);
    // A null view has no honest line count, because the change was too large to map.
    const text = if (rendered.views == null)
        try std.fmt.allocPrint(out, "The tool replaced {d} match(es).", .{matches})
    else
        try std.fmt.allocPrint(out, "The tool replaced {d} match(es) and changed {d} line(s).", .{ matches, rendered.changed_lines });

    try host.writeFile(scratch, path, new);
    return .{ .text = text, .view = rendered.views };
}

const testing = std.testing;

const FileHost = test_host.FileHost;

test "edit rejects a replace_all that grows the file above the cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 600_000 matches each grow by 19 bytes, so the 12 MB result passes the 10 MiB cap.
    const old = try a.alloc(u8, 600_000);
    @memset(old, 'a');
    var fake: FileHost = .{ .content = old };
    const args: Args = .{
        .path = .{ .bytes = "big.txt" },
        .old_string = .{ .bytes = "a" },
        .new_string = .{ .bytes = "0123456789012345678a" },
        .replace_all = true,
    };
    try testing.expectError(error.TooLarge, execute(a, a, fake.host(), args));
    try testing.expect(fake.written == null); // the guard runs before the write
}

test "edit replaces one unique match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .content = "alpha\nbeta\ngamma\n" };
    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"a\",\"old_string\":\"beta\",\"new_string\":\"delta\"}");
    try testing.expectEqualStrings("alpha\ndelta\ngamma\n", fake.written.?);
    try testing.expectEqualStrings("The tool replaced 1 match(es) and changed 2 line(s).", res.text);

    // Matches never overlap, so "aa" appears one time in "aaa" and the gate accepts it.
    var overlap: FileHost = .{ .content = "aaa" };
    _ = try tool.execute(a, a, overlap.host(), "{\"path\":\"a\",\"old_string\":\"aa\",\"new_string\":\"X\"}");
    try testing.expectEqualStrings("Xa", overlap.written.?);
}

test "edit refuses several matches unless replace_all is true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .content = "x\nx\n" };
    try testing.expectError(error.Ambiguous, tool.execute(a, a, fake.host(), "{\"path\":\"a\",\"old_string\":\"x\",\"new_string\":\"y\"}"));
    try testing.expect(fake.written == null); // A refused edit must not write the file.

    const res = try tool.execute(a, a, fake.host(), "{\"path\":\"a\",\"old_string\":\"x\",\"new_string\":\"y\",\"replace_all\":true}");
    try testing.expectEqualStrings("y\ny\n", fake.written.?);
    try testing.expectEqualStrings("The tool replaced 2 match(es) and changed 4 line(s).", res.text);
}

test "edit refuses a missing match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .content = "alpha\n" };
    try testing.expectError(error.NoMatch, tool.execute(a, a, fake.host(), "{\"path\":\"a\",\"old_string\":\"zeta\",\"new_string\":\"y\"}"));
    try testing.expect(fake.written == null);
}

test "edit refuses an argument pair that names no edit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FileHost = .{ .content = "alpha\n" };
    const backend = fake.host();
    try testing.expectError(error.InvalidArg, tool.execute(a, a, backend, "{\"path\":\"a\",\"old_string\":\"\",\"new_string\":\"y\"}"));
    try testing.expectError(error.NoChange, tool.execute(a, a, backend, "{\"path\":\"a\",\"old_string\":\"alpha\",\"new_string\":\"alpha\"}"));
    try testing.expect(fake.written == null);
}

test "edit stops on every full-read error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_]h.HostError{ error.NotFound, error.TooLarge, error.InvalidUtf8 }) |err| {
        var fake: FileHost = .{ .read_error = err };
        try testing.expectError(err, tool.execute(a, a, fake.host(), "{\"path\":\"a\",\"old_string\":\"x\",\"new_string\":\"y\"}"));
        try testing.expect(fake.written == null);
    }
}
