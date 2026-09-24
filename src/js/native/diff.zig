//! The native `yuke:diff` module describes one text change as bounded unified hunks for the reader; the model never sees the view.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const diff = @import("../../diff/diff.zig");
const pending = @import("../pending.zig");

const resolved = pending.resolved;
const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The largest side this module compares. A line table costs about 20 bytes for each line.
const max_side_bytes: usize = 1024 * 1024;

/// Register `yuke:diff` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:diff", &.{
        .{ .name = "diff", .arity = 3, .call = jsDiff },
    });
}

/// Compare two texts and answer `{path, hunks}`, or no hunk for an equal pair, a side above the cap, or a change too large to describe.
fn jsDiff(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 3) return rejected(ctx, "diff needs a path, an old text, and a new text");

    const path = module.string(ctx, args[0]) orelse return rejected(ctx, "the path must be a string");
    defer ctx.freeCString(path.ptr);
    const old = module.string(ctx, args[1]) orelse return rejected(ctx, "the old text must be a string");
    defer ctx.freeCString(old.ptr);
    const new = module.string(ctx, args[2]) orelse return rejected(ctx, "the new text must be a string");
    defer ctx.freeCString(new.ptr);

    var arena_state: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The line tables come before the search cap, so a large side must stop the compare here.
    const hunks: []const diff.Hunk = if (old.len > max_side_bytes or new.len > max_side_bytes)
        &.{}
    else
        diff.compare(arena, old, new, .{}) catch |err| switch (err) {
            error.TooDifferent => &.{}, // The change is too large for a reader-friendly view.
            error.OutOfMemory => unreachable,
        };

    return resolved(ctx, module.finish(ctx, fileOf(ctx, arena, path, hunks)));
}

/// Build `{path, hunks}`. The caller reads the exception once the whole value is built.
fn fileOf(ctx: Context, arena: std.mem.Allocator, path: []const u8, hunks: []const diff.Hunk) Value {
    const out = ctx.newObject();
    module.set(ctx, out, "path", ctx.newString(path));
    const list = ctx.newArray();
    module.set(ctx, out, "hunks", list);
    for (hunks, 0..) |hunk, i| module.setIndex(ctx, list, i, hunkOf(ctx, arena, hunk));
    return out;
}

/// Build one hunk. The start values stay as the difference states them: 1-based, 0 for an empty side.
fn hunkOf(ctx: Context, arena: std.mem.Allocator, hunk: diff.Hunk) Value {
    const out = ctx.newObject();
    module.set(ctx, out, "oldStart", ctx.newInt64(hunk.old_start));
    module.set(ctx, out, "oldLines", ctx.newInt64(hunk.old_lines));
    module.set(ctx, out, "newStart", ctx.newInt64(hunk.new_start));
    module.set(ctx, out, "newLines", ctx.newInt64(hunk.new_lines));
    const list = ctx.newArray();
    module.set(ctx, out, "lines", list);
    for (hunk.lines, 0..) |line, i| {
        // The wire carries plain strings. The leading mark identifies the operation.
        const mark: u8 = switch (line.op) {
            .keep => ' ',
            .delete => '-',
            .insert => '+',
        };
        const text = std.fmt.allocPrint(arena, "{c}{s}", .{ mark, line.text }) catch unreachable;
        module.setIndex(ctx, list, i, ctx.newString(text));
    }
    return out;
}
