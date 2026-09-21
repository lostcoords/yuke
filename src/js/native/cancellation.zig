//! Native cancellation state outlives its source while an operation holds the signal.

const std = @import("std");
const quickjs = @import("quickjs");
const c = @import("quickjs_c");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const pending = @import("../pending.zig");
const Context = quickjs.Context;
const Value = quickjs.Value;

pub const Signal = struct {
    aborted: bool = false,
    operations: usize = 0,
    has_waiter: bool = false,

    pub fn retain(self: *Signal) void {
        std.debug.assert(!self.aborted);
        std.debug.assert(self.operations < std.math.maxInt(usize));
        self.operations += 1;
    }

    pub fn release(self: *Signal, ctx: Context) bool {
        std.debug.assert(self.operations > 0);
        self.operations -= 1;
        if (self.operations != 0 or !self.has_waiter) return false;
        std.debug.assert(self.aborted);
        const host = Host.fromContext(ctx);
        for (host.signal_waiters.items, 0..) |waiter, index| {
            if (get(ctx, waiter.signal) != self) continue;
            _ = host.signal_waiters.swapRemove(index);
            self.has_waiter = false;
            defer waiter.free(ctx);
            const result = ctx.call(waiter.resolve, quickjs.UNDEFINED, &.{});
            defer ctx.freeValue(result);
            return ctx.isException(result);
        }
        unreachable;
    }
};

pub const Waiter = struct {
    signal: Value,
    promise: Value,
    resolve: Value,

    pub fn free(self: Waiter, ctx: Context) void {
        ctx.freeValue(self.resolve);
        ctx.freeValue(self.promise);
        ctx.freeValue(self.signal);
    }
};

pub fn deinit(host: *Host) void {
    for (host.signal_waiters.items) |waiter| {
        const signal = get(host.ctx, waiter.signal).?;
        std.debug.assert(signal.operations == 0);
        signal.has_waiter = false;
        waiter.free(host.ctx);
    }
    host.signal_waiters.deinit(host.gpa);
}

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:cancellation-native", &.{
        .{ .name = "create", .arity = 0, .call = jsCreate },
        .{ .name = "cancel", .arity = 1, .call = jsCancel },
        .{ .name = "drain", .arity = 1, .call = jsDrain },
    });
}

/// True when `value` is a signal that was canceled. An undefined or foreign value is not aborted.
pub fn aborted(ctx: Context, value: Value) bool {
    return if (get(ctx, value)) |signal| signal.aborted else false;
}

pub fn get(ctx: Context, value: Value) ?*Signal {
    if (!ctx.isObject(value)) return null;
    const id = Host.fromContext(ctx).signal_class_id;
    if (id == 0) return null;
    const ptr = ctx.getOpaque(value, id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn raw(value: Value) ?*Signal {
    var id: quickjs.ClassID = 0;
    const ptr = (Context{ .ptr = null }).getAnyOpaque(value, &id) orelse return null;
    std.debug.assert(id != 0);
    return @ptrCast(@alignCast(ptr));
}

fn finalize(runtime: quickjs.RuntimeHandle, value: Value) void {
    const signal = raw(value) orelse return;
    std.debug.assert(signal.operations == 0);
    std.debug.assert(!signal.has_waiter);
    c.js_free_rt(runtime.ptr, signal);
}

fn ensureClass(host: *Host) !void {
    if (host.signal_class_id != 0) return;
    const ctx = host.ctx;
    const id = host.runtime.newClassID();
    try host.runtime.newClass(id, .{ .name = "CancellationSignal", .finalizer = finalize });
    const proto = ctx.newObjectProto(quickjs.NULL);
    errdefer ctx.freeValue(proto);
    const key = ctx.newAtomZ("aborted");
    defer ctx.freeAtom(key);
    const getter = c.JS_NewCFunction2(ctx.ptr, @ptrCast(&jsAborted), "get aborted", 0, c.JS_CFUNC_getter, 0);
    _ = try ctx.definePropertyGetSet(proto, key, getter, quickjs.UNDEFINED, .{ .configurable = false, .writable = false, .enumerable = true, .normal = false, .getset = true });
    _ = try ctx.preventExtensions(proto);
    ctx.setClassProto(id, proto);
    host.signal_class_id = id;
}

pub fn create(host: *Host) Value {
    const ctx = host.ctx;
    std.debug.assert(host.acceptsIo());
    ensureClass(host) catch return ctx.throwOutOfMemory();
    const value = ctx.newObjectClass(host.signal_class_id);
    if (ctx.isException(value)) return value;
    const memory = c.js_malloc(ctx.ptr, @sizeOf(Signal)) orelse {
        ctx.freeValue(value);
        return module.throwPending(ctx);
    };
    const signal: *Signal = @ptrCast(@alignCast(memory));
    signal.* = .{};
    std.debug.assert(ctx.setOpaque(value, signal) == 0);
    _ = ctx.preventExtensions(value) catch {
        ctx.freeValue(value);
        return module.throwPending(ctx);
    };
    return value;
}

pub fn cancel(host: *Host, value: Value) void {
    const signal = get(host.ctx, value) orelse unreachable;
    if (signal.aborted) return;
    signal.aborted = true;
    host.ops.abortSignal(host.ctx, value);
    host.interactions.cancelSignal(host.ctx, value);
}

fn jsCreate(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (!host.acceptsIo()) return ctx.throwTypeError("the host is closed");
    return create(host);
}

fn jsAborted(ctx_ptr: ?*c.JSContext, value: Value) callconv(.c) Value {
    const ctx: Context = .{ .ptr = ctx_ptr };
    const signal = get(ctx, value) orelse return ctx.throwTypeError("invalid cancellation signal");
    return ctx.newBool(signal.aborted);
}

fn jsCancel(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len != 1 or get(ctx, args[0]) == null) return ctx.throwTypeError("invalid cancellation signal");
    const host = Host.fromContext(ctx);
    if (host.acceptsIo()) cancel(host, args[0]) else get(ctx, args[0]).?.aborted = true;
    return quickjs.UNDEFINED;
}

fn jsDrain(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len != 1) return ctx.throwTypeError("drain needs a cancellation signal");
    const signal = get(ctx, args[0]) orelse return ctx.throwTypeError("invalid cancellation signal");
    if (!signal.aborted) return ctx.throwTypeError("cancel the signal before drain");
    const host = Host.fromContext(ctx);
    if (signal.has_waiter) {
        for (host.signal_waiters.items) |waiter| {
            if (ctx.isStrictEqual(waiter.signal, args[0])) return ctx.dupValue(waiter.promise);
        }
        unreachable;
    }
    if (signal.operations == 0) return pending.resolved(ctx, quickjs.UNDEFINED);
    var funcs: [2]Value = undefined;
    const promise = ctx.newPromiseCapability(&funcs);
    if (ctx.isException(promise)) return promise;
    ctx.freeValue(funcs[1]);
    host.signal_waiters.append(host.gpa, .{ .signal = ctx.dupValue(args[0]), .promise = ctx.dupValue(promise), .resolve = funcs[0] }) catch unreachable;
    signal.has_waiter = true;
    return promise;
}
