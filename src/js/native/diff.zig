//! The native `yuke:diff` module: describe one text change as unified hunks.
//!
//! A tool that writes a file calls this to build the view a reader sees.
//! The model reads the tool text, never the view.
//! The compare is bounded, so it stays on the owner.
//! The call answers a Promise like every other primitive, so a later move to a task changes no JavaScript.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const diff = @import("../../diff/diff.zig");
const pending = @import("../pending.zig");

const resolved = pending.resolved;
const rejected = pending.rejected;

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;

/// The largest side this module compares. A line table costs about 20 bytes for each line.
pub const max_side_bytes: usize = 1024 * 1024;

/// Register the closed `yuke:diff` module and export `diff`.
pub fn install(host: *Host) error{OutOfMemory}!void {
    std.debug.assert(host.phase == .open);
    const m = host.ctx.newModule("yuke:diff", init) orelse return error.OutOfMemory;
    host.ctx.addModuleExport(m, "diff") catch return error.OutOfMemory;
}

fn init(ctx: Context, m: Module) c_int {
    std.debug.assert(Host.fromContext(ctx).phase == .open);
    ctx.setModuleExport(m, "diff", ctx.newFunction("diff", 3, jsDiff)) catch return -1;
    return 0;
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

    const path = stringArg(ctx, args[0]) orelse return rejected(ctx, "the path must be a string");
    defer ctx.freeCString(path.ptr);
    const old = stringArg(ctx, args[1]) orelse return rejected(ctx, "the old text must be a string");
    defer ctx.freeCString(old.ptr);
    const new = stringArg(ctx, args[2]) orelse return rejected(ctx, "the new text must be a string");
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
            error.OutOfMemory => return rejected(ctx, "out of memory"),
        };

    const file = fileOf(ctx, arena, path, hunks) catch return rejected(ctx, "out of memory");
    return resolved(ctx, file);
}

/// Build `{path, hunks}`. Every failure here is a failed allocation inside QuickJS.
fn fileOf(ctx: Context, arena: std.mem.Allocator, path: []const u8, hunks: []const diff.Hunk) error{OutOfMemory}!Value {
    const out = ctx.newObject();
    if (ctx.isException(out)) return error.OutOfMemory;
    errdefer ctx.freeValue(out);

    try set(ctx, out, "path", ctx.newString(path));
    const list = ctx.newArray();
    if (ctx.isException(list)) return error.OutOfMemory;
    // `set` takes the array reference, so the loop below writes through the one the object holds.
    try set(ctx, out, "hunks", list);

    for (hunks, 0..) |hunk, i| {
        const mapped = try hunkOf(ctx, arena, hunk);
        try append(ctx, list, i, mapped);
    }
    return out;
}

/// Build one hunk. The start values stay as the difference states them: 1-based, 0 for an empty side.
fn hunkOf(ctx: Context, arena: std.mem.Allocator, hunk: diff.Hunk) error{OutOfMemory}!Value {
    const out = ctx.newObject();
    if (ctx.isException(out)) return error.OutOfMemory;
    errdefer ctx.freeValue(out);

    try set(ctx, out, "oldStart", ctx.newInt64(hunk.old_start));
    try set(ctx, out, "oldLines", ctx.newInt64(hunk.old_lines));
    try set(ctx, out, "newStart", ctx.newInt64(hunk.new_start));
    try set(ctx, out, "newLines", ctx.newInt64(hunk.new_lines));

    const list = ctx.newArray();
    if (ctx.isException(list)) return error.OutOfMemory;
    try set(ctx, out, "lines", list);

    for (hunk.lines, 0..) |line, i| {
        // The wire carries plain strings. The leading mark identifies the operation.
        const mark: u8 = switch (line.op) {
            .keep => ' ',
            .delete => '-',
            .insert => '+',
        };
        const text = try std.fmt.allocPrint(arena, "{c}{s}", .{ mark, line.text });
        try append(ctx, list, i, ctx.newString(text));
    }
    return out;
}

/// Borrow one string argument. A value of another type answers null; nothing is converted.
fn stringArg(ctx: Context, value: Value) ?[:0]const u8 {
    if (!ctx.isString(value)) return null;
    return ctx.toCStringLen(value) catch null;
}

/// Set one property. `setPropertyStr` takes the value even when it fails, so this never frees it.
fn set(ctx: Context, obj: Value, name: [:0]const u8, value: Value) error{OutOfMemory}!void {
    if (ctx.isException(value)) return error.OutOfMemory;
    ctx.setPropertyStr(obj, name, value) catch return error.OutOfMemory;
}

/// Append one entry. `setPropertyUint32` takes the value even when it fails.
fn append(ctx: Context, list: Value, index: usize, value: Value) error{OutOfMemory}!void {
    if (ctx.isException(value)) return error.OutOfMemory;
    ctx.setPropertyUint32(list, @intCast(index), value) catch return error.OutOfMemory;
}
