//! One in-flight primitive call: a task writes a plain result into its `Op` and wakes the owner, and only the owner settles the promise.

const std = @import("std");
const quickjs = @import("quickjs");
const cancellation = @import("native/cancellation.zig");
const cancel = @import("../cancel.zig");
const module = @import("native/module.zig");
const Work = @import("../session/work.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// A response owns its buffers until the owner settles or discards it.
pub const Http = struct {
    status: u16,
    /// The parked body id, or zero when the response has no body.
    body: u32,
    headers: []Header,

    pub const Header = struct {
        name: [:0]u8,
        value: []u8,

        pub fn free(self: Header, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.value);
        }
    };

    fn deinit(self: Http, gpa: std.mem.Allocator) void {
        for (self.headers) |header| header.free(gpa);
        gpa.free(self.headers);
    }

    fn toJs(self: Http, ctx: Context) Value {
        const object = ctx.newObject();
        if (ctx.isException(object)) return object;
        module.set(ctx, object, "status", ctx.newUint32(self.status));
        module.set(ctx, object, "body", ctx.newUint32(self.body));
        const headers = ctx.newObjectProto(quickjs.NULL);
        for (self.headers) |header| module.set(ctx, headers, header.name, ctx.newString(header.value));
        module.set(ctx, object, "headers", headers);
        if (ctx.hasException()) {
            ctx.freeValue(object);
            return module.throwPending(ctx);
        }
        return object;
    }
};

/// A task transfers owned buffers to the owner; failure messages and codes are static.
pub const Result = union(enum) {
    bytes: struct { buffer: []u8, len: usize },
    number: u32,
    http: Http,
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
            .http => |http| http.deinit(gpa),
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

/// The results a task answers when a stop is not the worker's own answer.
pub const Failures = struct { canceled: Result, timed_out: Result, failed: Result };

/// Run `worker(host, op, payload, *result)` under the op's cancel token until `timeout`. A canceled, late, or unstartable worker maps through `failures`.
pub fn runTimed(host: anytype, op: *Op, timeout: std.Io.Timeout, comptime worker: anytype, payload: anytype, failures: Failures) Result {
    var result: Result = failures.canceled;
    if (op.cancel.isRequested()) return result;
    if (timeout == .deadline and timeout.deadline.durationFromNow(host.io).raw.nanoseconds <= 0) return failures.timed_out;
    const outcome = op.cancel.runChildTimeout(host.io, timeout, worker, .{ host, op, payload, &result }) catch {
        result.deinit(host.gpa);
        return failures.timed_out;
    };
    switch (outcome) {
        .returned => |returned| returned catch {
            result.deinit(host.gpa);
            return failures.failed;
        },
        .canceled, .aborted => {
            result.deinit(host.gpa);
            return failures.canceled;
        },
    }
    return result;
}

/// Every op this host has started and not yet settled. The owner drains it between frames.
pub const Ops = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    wake: *std.Io.Event,
    live: std.ArrayList(*Op) = .empty,
    /// Settled records wait here, so a steady stream of ops allocates none.
    spare: std.ArrayList(*Op) = .empty,

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
        for (self.spare.items) |op| self.gpa.destroy(op);
        self.live.deinit(self.gpa);
        self.spare.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start one op and answer its pending promise. Null means the QuickJS heap is full, and the exception stays pending for the caller.
    pub fn start(self: *Ops, ctx: Context) ?struct { op: *Op, promise: Value } {
        var funcs: [2]Value = undefined;
        const promise = ctx.newPromiseCapability(&funcs);
        if (ctx.isException(promise)) return null;
        const op = self.spare.pop() orelse self.gpa.create(Op) catch unreachable;
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
            self.spare.append(self.gpa, op) catch unreachable;
        }
        return faulted;
    }

    /// Answer whether the resolver threw; the caller clears the pending exception and reports the fault.
    fn call(ctx: Context, op: *Op, result: Result) bool {
        const failed = result == .failed;
        const value = switch (result) {
            .bytes => |bytes| ctx.newUint8ArrayCopy(bytes.buffer[0..bytes.len]),
            .number => |number| ctx.newUint32(number),
            .http => |http| http.toJs(ctx),
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
