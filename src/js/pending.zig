//! One in-flight primitive call: a task writes a plain result into its `Op` and wakes the owner, and only the owner settles the promise.

const std = @import("std");
const quickjs = @import("quickjs");
const cancellation = @import("native/cancellation.zig");
const cancel = @import("../cancel.zig");
const Work = @import("../session/work.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// A task transfers owned buffers to the owner; failure messages and codes are static.
pub const Result = union(enum) {
    bytes: struct { buffer: []u8, len: usize },
    number: u32,
    null_value,
    text: []u8,
    /// A structured answer, as the JSON text the owner parses. QuickJS reads it to the sentinel.
    json: [:0]u8,
    boolean: bool,
    undefined,
    failed: Failure,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        switch (self) {
            .bytes => |bytes| gpa.free(bytes.buffer),
            .text => |text| gpa.free(text),
            .json => |bytes| gpa.free(bytes),
            else => {},
        }
    }
};

/// A static operation error with an optional code for command refusals.
pub const Failure = struct {
    message: []const u8,
    code: ?[]const u8 = null,
};

/// Answer a resolved promise. `JS_NewSettledPromise` borrows the value, so this frees it.
pub fn resolved(ctx: Context, value: Value) Value {
    defer ctx.freeValue(value);
    return ctx.newSettledPromise(false, value);
}

/// Answer a rejected promise that carries an Error, so `catch (e)` reads `e.message`, and leave no exception pending.
pub fn rejected(ctx: Context, message: []const u8) Value {
    return rejectedWith(ctx, .{ .message = message });
}

pub fn rejectedWith(ctx: Context, failure: Failure) Value {
    dropException(ctx);
    const err = errorWith(ctx, failure) orelse return ctx.newSettledPromise(true, quickjs.UNDEFINED);
    defer ctx.freeValue(err);
    return ctx.newSettledPromise(true, err);
}

/// Build one Error, or answer null with the exception cleared when the QuickJS heap is full.
fn errorWith(ctx: Context, failure: Failure) ?Value {
    const err = ctx.newError();
    if (!ctx.isException(err)) ctx.setPropertyStr(err, "message", ctx.newString(failure.message)) catch {};
    if (!ctx.hasException()) if (failure.code) |code| ctx.setPropertyStr(err, "code", ctx.newString(code)) catch {};
    if (!ctx.hasException()) return err;
    ctx.freeValue(err);
    dropException(ctx);
    return null;
}

/// Free the exception QuickJS left, so the next call starts from a clean context.
pub fn dropException(ctx: Context) void {
    if (ctx.hasException()) ctx.freeValue(ctx.getException());
}

pub const Op = struct {
    /// The resolving functions, held as GC roots until this op settles.
    resolve: Value,
    reject: Value,
    /// The owner sleeps on this. The op captures it so a task needs nothing but its own pointer.
    wake: *std.Io.Event,
    /// Null while the task runs. The task writes it once, and the owner reads it once.
    result: ?Result = null,
    done: std.atomic.Value(bool) = .init(false),
    /// The cancellation signal remains rooted until this op leaves the table.
    signal: Value = quickjs.UNDEFINED,
    /// The task uses this token to interrupt work after a call abort.
    cancel: cancel.Cancel = .{},
    work: ?*Work = null,
    io: std.Io,
    operation: Work.Operation = .{ .cancel = cancelOperation },

    fn cancelOperation(operation: *Work.Operation) void {
        const self: *Op = @fieldParentPtr("operation", operation);
        std.debug.assert(!self.done.load(.acquire));
        self.cancel.request(self.io);
    }

    /// Record the outcome and wake the owner. This runs on a task, so it enters no JavaScript and touches nothing after the wake.
    pub fn finish(self: *Op, result: Result) void {
        std.debug.assert(self.result == null); // a task finishes its op once
        if (self.work) |work| {
            work.release(self.io, &self.operation);
            self.work = null;
        }
        self.result = result;
        const wake = self.wake;
        const io = self.io;
        self.done.store(true, .release);
        wake.set(io);
    }
};

/// Every op this host has started and not yet settled. The owner drains it between frames.
pub const Ops = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    wake: *std.Io.Event,
    live: std.ArrayList(*Op) = .empty,

    pub fn deinit(self: *Ops, ctx: Context) void {
        // A host that dies with work in flight frees the roots itself; nothing settles after this.
        for (self.live.items) |op| {
            std.debug.assert(op.work == null);
            ctx.freeValue(op.resolve);
            ctx.freeValue(op.reject);
            if (!ctx.isUndefined(op.signal)) {
                const signal = cancellation.get(ctx, op.signal).?;
                std.debug.assert(signal.operations > 0);
                signal.operations -= 1;
            }
            ctx.freeValue(op.signal);
            if (op.result) |r| r.deinit(self.gpa);
            self.gpa.destroy(op);
        }
        self.live.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start one op and answer its pending promise. Null means the QuickJS heap is full, and the exception stays pending for the caller.
    pub fn start(self: *Ops, ctx: Context) ?struct { op: *Op, promise: Value } {
        var funcs: [2]Value = undefined;
        const promise = ctx.newPromiseCapability(&funcs);
        if (ctx.isException(promise)) return null;
        const op = self.gpa.create(Op) catch unreachable;
        op.* = .{ .resolve = funcs[0], .reject = funcs[1], .wake = self.wake, .io = self.io };
        self.live.append(self.gpa, op) catch unreachable;
        return .{ .op = op, .promise = promise };
    }

    /// Request cleanup without a join on the QuickJS owner.
    pub fn abortSignal(self: *Ops, ctx: Context, signal: Value) void {
        std.debug.assert(ctx.isObject(signal));
        for (self.live.items) |op| {
            if (op.done.load(.acquire) or !ctx.isStrictEqual(op.signal, signal)) continue;
            op.cancel.request(self.io);
        }
    }

    /// Report whether any op finished. The owner asks before it sleeps.
    pub fn anyDone(self: *const Ops) bool {
        for (self.live.items) |op| if (op.done.load(.acquire)) return true;
        return false;
    }

    /// Settle every finished op and report whether a resolver threw; a settle can start another op, so the loop re-reads the length.
    pub fn settle(self: *Ops, ctx: Context) bool {
        var faulted = false;
        var i: usize = 0;
        while (i < self.live.items.len) {
            const op = self.live.items[i];
            if (!op.done.load(.acquire)) {
                i += 1;
                continue;
            }
            const result = op.result.?;
            _ = self.live.orderedRemove(i);
            if (call(ctx, op, result)) faulted = true;
            if (!ctx.isUndefined(op.signal)) {
                if (cancellation.get(ctx, op.signal).?.release(ctx)) faulted = true;
            }
            result.deinit(self.gpa);
            ctx.freeValue(op.resolve);
            ctx.freeValue(op.reject);
            ctx.freeValue(op.signal);
            self.gpa.destroy(op);
        }
        return faulted;
    }

    /// Answer whether the resolver threw; the caller clears the pending exception and reports the fault.
    fn call(ctx: Context, op: *Op, result: Result) bool {
        const failed = result == .failed;
        const value = switch (result) {
            .bytes => |bytes| ctx.newUint8ArrayCopy(bytes.buffer[0..bytes.len]),
            .number => |number| ctx.newUint32(number),
            .null_value => quickjs.NULL,
            .text => |text| ctx.newString(text),
            // A task builds this text, so a parse failure is our bug, not the caller's input.
            .json => |bytes| ctx.parseJSON(bytes, "yuke:primitive"),
            .boolean => |value| ctx.newBool(value),
            .undefined => quickjs.UNDEFINED,
            .failed => |failure| errorWith(ctx, failure) orelse quickjs.UNDEFINED,
        };
        // A failed conversion is an exception value no resolver may see, so clear it and reject with undefined to leave the pending set.
        if (ctx.isException(value)) {
            const exc = ctx.getException();
            ctx.freeValue(exc);
            var undef = [_]Value{quickjs.UNDEFINED};
            const answer = ctx.call(op.reject, quickjs.UNDEFINED, &undef);
            defer ctx.freeValue(answer);
            return true;
        }
        defer ctx.freeValue(value);
        var argv = [_]Value{value};
        const target = if (failed) op.reject else op.resolve;
        const answer = ctx.call(target, quickjs.UNDEFINED, &argv);
        defer ctx.freeValue(answer);
        return ctx.isException(answer);
    }
};
