//! One in-flight primitive call: a promise a task finishes and the owner settles.
//!
//! A task never touches JavaScript. It writes a plain result into its `Op` and wakes the owner,
//! which is the only place that calls `resolve` or `reject`. This is the rule `Engine.onEvent`
//! already follows for events, so a primitive and an event reach JavaScript by the same route.
//!
//! The executor is cooperative, so a task only runs while another task suspends. `settle` never
//! suspends, which is why it can walk its own list safely and why one pass settles everything.
//! The owner must therefore reach a suspension point for any of this to progress; `serve` does,
//! because it ends each pass in `receive`.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// What a finished task hands back. `text` and `json` are owned; `failed` names a closed error set, so it is static.
pub const Result = union(enum) {
    text: []u8,
    /// A structured answer, as the JSON text the owner parses. QuickJS reads it to the sentinel.
    json: [:0]u8,
    boolean: bool,
    undefined,
    failed: Failure,
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
    wake: *zio.ResetEvent,
    /// Null while the task runs. The task writes it once, and the owner reads it once.
    result: ?Result = null,

    /// Record the outcome and wake the owner. This runs on a task, so it enters no JavaScript and touches nothing after the wake.
    pub fn finish(self: *Op, result: Result) void {
        std.debug.assert(self.result == null); // a task finishes its op once
        self.result = result;
        self.wake.set();
    }
};

/// Every op this host has started and not yet settled. The owner drains it between frames.
pub const Ops = struct {
    gpa: std.mem.Allocator,
    wake: *zio.ResetEvent,
    live: std.ArrayList(*Op) = .empty,

    pub fn deinit(self: *Ops, ctx: Context) void {
        // A host that dies with work in flight frees the roots itself; nothing settles after this.
        for (self.live.items) |op| {
            ctx.freeValue(op.resolve);
            ctx.freeValue(op.reject);
            if (op.result) |r| self.freeResult(r);
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
        op.* = .{ .resolve = funcs[0], .reject = funcs[1], .wake = self.wake };
        self.live.append(self.gpa, op) catch unreachable;
        return .{ .op = op, .promise = promise };
    }

    /// Report whether any op finished. The owner asks before it sleeps.
    pub fn anyDone(self: *const Ops) bool {
        for (self.live.items) |op| if (op.result != null) return true;
        return false;
    }

    /// Settle every finished op and answer whether a resolver threw. A settle can start another op, so the loop re-reads the length and holds `i` after a removal.
    pub fn settle(self: *Ops, ctx: Context) bool {
        var faulted = false;
        var i: usize = 0;
        while (i < self.live.items.len) {
            const op = self.live.items[i];
            const result = op.result orelse {
                i += 1;
                continue;
            };
            _ = self.live.orderedRemove(i);
            if (call(ctx, op, result)) faulted = true;
            self.freeResult(result);
            ctx.freeValue(op.resolve);
            ctx.freeValue(op.reject);
            self.gpa.destroy(op);
        }
        return faulted;
    }

    /// Answer whether the resolver threw; the caller clears the pending exception and reports the fault.
    fn call(ctx: Context, op: *Op, result: Result) bool {
        const failed = result == .failed;
        const value = switch (result) {
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

    fn freeResult(self: *Ops, result: Result) void {
        switch (result) {
            .text => |text| self.gpa.free(text),
            .json => |bytes| self.gpa.free(bytes),
            else => {}, // an int, a null, and a static message own nothing
        }
    }
};
