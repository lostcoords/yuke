//! The native `yuke:diff` module: describe one text change as unified hunks.
//!
//! A tool that writes a file calls this to build the view a reader sees.
//! The model reads the tool text, never the view.
//! The compare is bounded, so it stays on the owner.
//! The call answers a Promise like every other primitive, so a later move to a task changes no JavaScript.

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
pub const max_side_bytes: usize = 1024 * 1024;

/// Register `yuke:diff` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:diff", &.{
        .{ .name = "diff", .arity = 3, .call = jsDiff },
    });
}

/// Compare two texts and answer `{path, hunks}`. `path` only labels the result.
///
/// Answer no hunk when the pair is equal, when a side is above the cap, or when the change is
/// too large to describe. A caller drops the view in each of the three cases.
///
/// A value that is not a string rejects. A conversion would run a script the argument carries.
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

    const file = fileOf(ctx, arena, path, hunks);
    // A full QuickJS heap throws at the caller, because no promise can be built for it either.
    if (ctx.hasException()) {
        ctx.freeValue(file);
        return module.throwPending(ctx);
    }
    return resolved(ctx, file);
}

/// Build `{path, hunks}`. The caller reads the exception once the whole value is built.
fn fileOf(ctx: Context, arena: std.mem.Allocator, path: []const u8, hunks: []const diff.Hunk) Value {
    const out = ctx.newObject();
    set(ctx, out, "path", ctx.newString(path));
    const list = ctx.newArray();
    // `set` takes the array reference, so the loop below writes through the one the object holds.
    set(ctx, out, "hunks", list);
    for (hunks, 0..) |hunk, i| append(ctx, list, i, hunkOf(ctx, arena, hunk));
    return out;
}

/// Build one hunk. The start values stay as the difference states them: 1-based, 0 for an empty side.
fn hunkOf(ctx: Context, arena: std.mem.Allocator, hunk: diff.Hunk) Value {
    const out = ctx.newObject();
    set(ctx, out, "oldStart", ctx.newInt64(hunk.old_start));
    set(ctx, out, "oldLines", ctx.newInt64(hunk.old_lines));
    set(ctx, out, "newStart", ctx.newInt64(hunk.new_start));
    set(ctx, out, "newLines", ctx.newInt64(hunk.new_lines));
    const list = ctx.newArray();
    set(ctx, out, "lines", list);
    for (hunk.lines, 0..) |line, i| {
        // The wire carries plain strings. The leading mark identifies the operation.
        const mark: u8 = switch (line.op) {
            .keep => ' ',
            .delete => '-',
            .insert => '+',
        };
        const text = std.fmt.allocPrint(arena, "{c}{s}", .{ mark, line.text }) catch unreachable;
        append(ctx, list, i, ctx.newString(text));
    }
    return out;
}

/// Set one property, or drop the value once the QuickJS heap is full; the caller reads the exception at the end.
fn set(ctx: Context, obj: Value, name: [:0]const u8, value: Value) void {
    if (ctx.hasException()) return ctx.freeValue(value);
    ctx.setPropertyStr(obj, name, value) catch {};
}

/// Append one entry under the same rule as `set`.
fn append(ctx: Context, list: Value, index: usize, value: Value) void {
    if (ctx.hasException()) return ctx.freeValue(value);
    ctx.setPropertyUint32(list, @intCast(index), value) catch {};
}
