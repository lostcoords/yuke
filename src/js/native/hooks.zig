//! The native `yuke:hooks` module: `yuke:ext` installs one chain folder and publishes its points.
//!
//! A chain folds in JavaScript, so this module registers no handler. It takes the one dispatcher
//! the runtime calls, and the point set a turn task reads to skip a call no handler wants.
//!
//! A refused call THROWS, because a plugin names its point and a typo must fail where it is written.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("../host.zig").Host;
const table = @import("../hooks.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;

/// Register the closed `yuke:hooks` module and export its two functions.
pub fn install(host: *Host) error{OutOfMemory}!void {
    std.debug.assert(host.phase == .open);
    const m = host.ctx.newModule("yuke:hooks", init) orelse return error.OutOfMemory;
    host.ctx.addModuleExport(m, "installDispatcher") catch return error.OutOfMemory;
    host.ctx.addModuleExport(m, "setPoints") catch return error.OutOfMemory;
}

fn init(ctx: Context, m: Module) c_int {
    std.debug.assert(Host.fromContext(ctx).phase == .open);
    ctx.setModuleExport(m, "installDispatcher", ctx.newFunction("installDispatcher", 1, jsInstallDispatcher)) catch return -1;
    ctx.setModuleExport(m, "setPoints", ctx.newFunction("setPoints", 1, jsSetPoints)) catch return -1;
    return 0;
}

/// `installDispatcher(fn)` takes the folder the runtime calls as `fn(point, payload)`.
fn jsInstallDispatcher(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1 or !ctx.isFunction(args[0])) return ctx.throwTypeError("installDispatcher needs a function");
    // The table takes this reference, so it must outlive the argument frame.
    host.hooks.install(ctx, ctx.dupValue(args[0]));
    return quickjs.UNDEFINED;
}

/// `setPoints(names)` states every point that now holds a handler. An unknown name throws.
fn jsSetPoints(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1 or !ctx.isArray(args[0])) return ctx.throwTypeError("setPoints needs an array of point names");

    const length = ctx.getPropertyStr(args[0], "length");
    defer ctx.freeValue(length);
    const count = ctx.toInt64(length) catch return exception(ctx);
    if (count < 0 or count > std.meta.tags(table.Point).len) return ctx.throwTypeError("setPoints holds more names than there are points");

    var points: table.PointSet = .initEmpty();
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        const item = ctx.getPropertyUint32(args[0], @intCast(i));
        defer ctx.freeValue(item);
        if (!ctx.isString(item)) return ctx.throwTypeError("a hook point must be a string");
        const name = ctx.toCStringLen(item) catch return exception(ctx);
        defer ctx.freeCString(name.ptr);
        const point = table.Point.parse(name) orelse return ctx.throwTypeError("no such hook point");
        points.insert(point);
    }
    host.hooks.setPoints(points);
    return quickjs.UNDEFINED;
}

/// Answer the exception sentinel and leave the pending exception in place.
fn exception(ctx: Context) Value {
    return ctx.throw(ctx.getException());
}

test {
    _ = proto.hook.Point;
}
