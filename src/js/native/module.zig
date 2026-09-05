//! One shape for every native module: a comptime table of functions, installed once at host creation.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;

const Context = quickjs.Context;
const Value = quickjs.Value;

/// One exported function: its name, its declared arity, and the Zig callback.
pub const Fn = struct { name: [:0]const u8, arity: c_int, call: fn (Context, Value, []const Value) Value };

/// A module whose exports are bare functions: `import { a, b } from "yuke:x"`.
pub fn installFunctions(host: *Host, comptime name: [:0]const u8, comptime fns: []const Fn) void {
    std.debug.assert(host.phase == .open);
    const Init = struct {
        fn init(ctx: Context, m: Context.Module) c_int {
            std.debug.assert(Host.fromContext(ctx).phase == .open);
            inline for (fns) |f| ctx.setModuleExport(m, f.name, ctx.newFunction(f.name, f.arity, f.call)) catch return -1;
            return 0;
        }
    };
    const m = host.ctx.newModule(name, Init.init).?;
    inline for (fns) |f| host.ctx.addModuleExport(m, f.name) catch unreachable;
}

/// A module with one object export that holds the functions; `extra` adds the constants and any host root.
pub fn installObject(
    host: *Host,
    comptime name: [:0]const u8,
    comptime as: [:0]const u8,
    comptime fns: []const Fn,
    comptime extra: ?fn (*Host, Context, Value) void,
) void {
    std.debug.assert(host.phase == .open);
    const Init = struct {
        fn init(ctx: Context, m: Context.Module) c_int {
            const h = Host.fromContext(ctx);
            std.debug.assert(h.phase == .open);
            const obj = ctx.newObject();
            inline for (fns) |f| set(ctx, obj, f.name, ctx.newFunction(f.name, f.arity, f.call));
            if (extra) |add| add(h, ctx, obj);
            // A full QuickJS heap at boot ends the module evaluation, which the host reports as a fault.
            if (ctx.hasException()) {
                ctx.freeValue(obj);
                return -1;
            }
            // `setModuleExport` takes `obj` on both paths, so nothing here frees it.
            ctx.setModuleExport(m, as, obj) catch return -1;
            return 0;
        }
    };
    const m = host.ctx.newModule(name, Init.init).?;
    host.ctx.addModuleExport(m, as) catch unreachable;
}

/// Throw the exception QuickJS left pending, and answer the sentinel a native function returns.
pub fn throwPending(ctx: Context) Value {
    return ctx.throw(ctx.getException());
}

/// Borrow one string argument. Another type answers null, because a conversion would run script code.
pub fn string(ctx: Context, value: Value) ?[:0]const u8 {
    if (!ctx.isString(value)) return null;
    return ctx.toCStringLen(value) catch null;
}

/// Copy one string argument for a task that outlives the call. Another type answers null.
pub fn owned(ctx: Context, gpa: std.mem.Allocator, value: Value) ?[]u8 {
    const raw = string(ctx, value) orelse return null;
    defer ctx.freeCString(raw.ptr);
    return gpa.dupe(u8, raw) catch unreachable;
}

/// Read one whole number in `[min, max]`. A fraction, a NaN, or another type answers null.
pub fn integer(ctx: Context, value: Value, min: u64, max: u64) ?u64 {
    if (!ctx.isNumber(value)) return null;
    const n = ctx.toFloat64(value) catch return null;
    if (!std.math.isFinite(n) or @floor(n) != n) return null;
    if (n < @as(f64, @floatFromInt(min)) or n > @as(f64, @floatFromInt(max))) return null;
    return @intFromFloat(n);
}

/// Set one property, or drop the value once the QuickJS heap is full; the builder reads the exception at its end.
pub fn set(ctx: Context, obj: Value, name: [:0]const u8, value: Value) void {
    if (ctx.hasException()) return ctx.freeValue(value);
    ctx.setPropertyStr(obj, name, value) catch {};
}
