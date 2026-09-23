//! The native hook module installs the dispatcher and validates the point set.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const table = @import("../hooks.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Register `yuke:hooks` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:hooks", &.{
        .{ .name = "installDispatcher", .arity = 1, .call = jsInstallDispatcher },
        .{ .name = "installLifecycle", .arity = 1, .call = jsInstallLifecycle },
        .{ .name = "setPoints", .arity = 2, .call = jsSetPoints },
    });
}

/// `installDispatcher(fn)` takes the folder the runtime calls as `fn(point, payload)`.
fn jsInstallDispatcher(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1 or !ctx.isFunction(args[0])) return ctx.throwTypeError("installDispatcher needs a function");
    // The table takes this reference, so it must outlive the argument frame.
    host.hooks.install(ctx, ctx.dupValue(args[0]));
    return quickjs.UNDEFINED;
}

/// `setPoints(names, changed)` states every point that now holds a handler and the point that changed. An unknown name throws.
fn jsSetPoints(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1 or !ctx.isArray(args[0])) return ctx.throwTypeError("setPoints needs an array of point names");

    const length = ctx.getPropertyStr(args[0], "length");
    defer ctx.freeValue(length);
    const count = ctx.toInt64(length) catch return module.throwPending(ctx);
    if (count < 0 or count > std.meta.tags(table.Point).len) return ctx.throwTypeError("setPoints holds more names than there are points");

    var points: table.PointSet = .initEmpty();
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        const item = ctx.getPropertyUint32(args[0], @intCast(i));
        defer ctx.freeValue(item);
        if (!ctx.isString(item)) return ctx.throwTypeError("a hook point must be a string");
        const name = ctx.toCStringLen(item) catch return module.throwPending(ctx);
        defer ctx.freeCString(name.ptr);
        const point = table.Point.parse(name) orelse return ctx.throwTypeError("no such hook point");
        points.insert(point);
    }
    // The second argument names the point that changed. A prompt handler joined or left, so every stored prompt is stale.
    if (args.len > 1 and ctx.isString(args[1])) {
        const changed = ctx.toCStringLen(args[1]) catch return module.throwPending(ctx);
        defer ctx.freeCString(changed.ptr);
        if (table.Point.parse(changed) == .@"prompt.build") if (host.engine.runtime) |runtime| {
            runtime.engine.prompt_generation += 1;
        };
    }
    host.hooks.setPoints(points);
    return quickjs.UNDEFINED;
}

/// The host owns the lifecycle callback until the context closes.
fn jsInstallLifecycle(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open or host.plugin_lifecycle != null) return ctx.throwTypeError("the plugin lifecycle is already installed or closed");
    if (args.len != 1 or !ctx.isFunction(args[0])) return ctx.throwTypeError("installLifecycle needs a function");
    host.plugin_lifecycle = ctx.dupValue(args[0]);
    return ctx.newInt32(host.plugin_stop_timeout_ms);
}
