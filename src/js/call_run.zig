//! The owner side of a tool, hook, or input call: start the handler, poll its promise, and settle the record.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("host.zig").Host;
const table = @import("tools.zig");
const utf8 = @import("../utf8.zig");
const pending = @import("pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Abort the signal of every left call before any continuation can read it.
pub fn abortLeft(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (!call.submitter_done or !host.ctx.isObject(call.signal)) continue;
        host.ops.abortSignal(host.ctx, call.signal);
        host.ctx.setPropertyStr(call.signal, "aborted", quickjs.TRUE) catch {};
        host.interactions.cancelSignal(host.ctx, call.signal);
    }
}

/// Start queued calls and poll running calls after the owner drains jobs.
pub fn pump(host: *Host) void {
    // A start can queue nothing new, so one pass over the list visits every call exactly once.
    for (host.calls.live.items) |call| switch (call.state) {
        .queued => if (!call.submitter_done) start(host, call),
        .running => if (!call.submitter_done) poll(host, call),
        .settled => {},
    };
    abortLeft(host);
    host.calls.sweep(host.ctx);
}

pub fn pollRunning(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (call.state == .running and !call.submitter_done) poll(host, call);
    }
}

/// Answer every waiting call, so a turn task never sleeps past the host. `Host.close` calls this.
pub fn abortAll(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (host.ctx.isObject(call.signal)) {
            host.ops.abortSignal(host.ctx, call.signal);
            host.ctx.setPropertyStr(call.signal, "aborted", quickjs.TRUE) catch {};
        }
        if (call.state == .settled or call.submitter_done) continue;
        call.settle(host.io, null, true);
    }
}

/// Invoke the handler this call names and retain its promise until it settles.
fn start(host: *Host, call: *table.Call) void {
    switch (call.kind) {
        .tool => startTool(host, call),
        .hook => startHook(host, call),
        .input => startInput(host, call),
    }
}

/// Parse the JSON the submitter wrote. A bad document settles the call and answers null.
fn parseArguments(host: *Host, call: *table.Call) ?Value {
    const text = host.gpa.dupeZ(u8, call.arguments) catch unreachable;
    defer host.gpa.free(text);
    const parsed = host.ctx.parseJSON(text, "call-arguments.json");
    if (!host.ctx.isException(parsed)) return parsed;
    pending.dropException(host.ctx);
    settleText(host, call, "the arguments are not valid JSON", true);
    return null;
}

/// Hand one point and its payload to the chain folder. The folder answers one Promise for the chain.
fn startHook(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    // A withdrawn folder answers no point, so the call proceeds rather than failing the round.
    const folder = host.hooks.dispatch orelse return settleText(host, call, "", false);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    const point = ctx.newString(call.name);
    if (ctx.isException(point)) {
        pending.dropException(ctx);
        return settleText(host, call, "out of memory", true);
    }
    defer ctx.freeValue(point);

    host.enterSlice();
    var argv = [_]Value{ point, parsed };
    const answer = ctx.call(folder, quickjs.UNDEFINED, &argv);
    acceptPromise(host, call, answer);
}

/// Hand one `session.send_input` to the gate. The gate answers `{result}` or `{failure}` and never rejects.
fn startInput(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const gate = host.hooks.gate orelse return settleText(host, call, "no input gate is installed", true);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    host.enterSlice();
    const method = ctx.newString(call.name);
    defer ctx.freeValue(method);
    var argv = [_]Value{ parsed, method };
    const answer = ctx.call(gate, quickjs.UNDEFINED, &argv);
    acceptPromise(host, call, answer);
}

fn startTool(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const at = host.tools.find(call.name) orelse
        return settleText(host, call, "the tool is not registered", true);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    // The handler reads `signal.aborted` between its awaits, so a canceled turn can stop early.
    call.signal = ctx.newObject();
    const context = ctx.newObject();
    if (!ctx.hasException()) {
        ctx.setPropertyStr(call.signal, "aborted", quickjs.FALSE) catch {};
        ctx.setPropertyStr(context, "workspaceRoot", ctx.newString(call.workspace_root)) catch {};
        if (call.site) |site| {
            const id = std.fmt.bytesToHex(site.session_id.raw, .lower);
            ctx.setPropertyStr(context, "sessionId", ctx.newString(&id)) catch {};
            ctx.setPropertyStr(context, "messageId", ctx.newInt64(@intCast(site.message_id))) catch {};
            ctx.setPropertyStr(context, "partId", ctx.newInt64(@intCast(site.part_id))) catch {};
        }
    }
    // A full QuickJS heap fails the call, not the host, so the two roots go and the call settles.
    if (ctx.hasException()) {
        ctx.freeValue(context);
        ctx.freeValue(call.signal);
        call.signal = quickjs.UNDEFINED;
        pending.dropException(ctx);
        return settleText(host, call, "out of memory", true);
    }
    defer ctx.freeValue(context);
    host.enterSlice();
    var argv = [_]Value{ parsed, call.signal, context };
    const answer = ctx.call(host.tools.entries.items[at].handler, quickjs.UNDEFINED, &argv);
    acceptPromise(host, call, answer);
}

fn acceptPromise(host: *Host, call: *table.Call, answer: Value) void {
    std.debug.assert(call.state == .queued);
    const ctx = host.ctx;
    if (ctx.isException(answer)) {
        const exc = ctx.getException();
        defer ctx.freeValue(exc);
        return settleValue(host, call, exc, true);
    }
    if (!ctx.isPromise(answer)) {
        ctx.freeValue(answer);
        return settleText(host, call, switch (call.kind) {
            .tool => "the tool execute function must return a Promise",
            .hook => "the hook dispatcher must return a Promise",
            .input => "the input gate must return a Promise",
        }, true);
    }
    call.promise = answer; // the call holds the root until it settles
    call.state = .running;
    poll(host, call);
}

/// Read one Promise. A pending Promise stays.
fn poll(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const state = ctx.promiseState(call.promise);
    if (state == .Pending) return;
    // A settle can run a user `toJSON` or getter, so it starts a fresh interrupt slice.
    host.enterSlice();
    const result = ctx.promiseResult(call.promise);
    defer ctx.freeValue(result);
    settleValue(host, call, result, state == .Rejected);
}

/// Convert a JavaScript answer to model text or a structured tool result.
fn settleValue(host: *Host, call: *table.Call, value: Value, is_error: bool) void {
    const ctx = host.ctx;
    if (is_error) {
        if (call.kind == .tool) call.cancellation_reason = cancellationReason(ctx, value);
        const message = errorText(ctx, value);
        defer if (message) |text| ctx.freeCString(text.ptr);
        const fallback: []const u8 = switch (call.kind) {
            .tool => "the tool failed",
            .hook => "the hook failed",
            .input => "the input gate failed",
        };
        return settleText(host, call, if (message) |text| text else fallback, true);
    }
    // An empty answer is the proceed decision for a hook, and empty output for a tool.
    if (ctx.isUndefined(value) or ctx.isNull(value)) return settleText(host, call, "", false);
    // A hook or the gate answers one object, which never carries model text or a view.
    if (call.kind != .tool) return stringifyValue(host, call, value);
    if (ctx.isString(value)) {
        const text = ctx.toCStringLen(value) catch {
            pending.dropException(ctx);
            return settleText(host, call, "the tool answered text the host cannot read", true);
        };
        defer ctx.freeCString(text.ptr);
        return settleText(host, call, text, false);
    }

    if (ctx.isObject(value) and !ctx.isArray(value)) {
        const marker = ctx.getPropertyStr(value, "__yuke_result");
        defer ctx.freeValue(marker);
        const marked = ctx.isBool(marker) and (ctx.toBool(marker) catch false);
        if (!marked) return stringifyValue(host, call, value);
        const text_value = ctx.getPropertyStr(value, "text");
        defer ctx.freeValue(text_value);
        if (ctx.isString(text_value)) {
            const text = ctx.toCStringLen(text_value) catch {
                pending.dropException(ctx);
                return settleText(host, call, "the tool answered text the host cannot read", true);
            };
            defer ctx.freeCString(text.ptr);
            const view_value = ctx.getPropertyStr(value, "view");
            defer ctx.freeValue(view_value);
            if (ctx.isUndefined(view_value) or ctx.isNull(view_value)) return settleText(host, call, text, false);
            const json = ctx.jsonStringify(view_value, quickjs.UNDEFINED, quickjs.UNDEFINED);
            defer ctx.freeValue(json);
            if (!ctx.isString(json)) {
                pending.dropException(ctx);
                return settleText(host, call, "the tool answered a view that is not JSON", true);
            }
            const view_text = ctx.toCStringLen(json) catch {
                pending.dropException(ctx);
                return settleText(host, call, "the tool answered a view that is not JSON", true);
            };
            defer ctx.freeCString(view_text.ptr);
            return settleTextAndView(host, call, text, view_text);
        }
    }

    return stringifyValue(host, call, value);
}

fn cancellationReason(ctx: Context, value: Value) ?proto.tool.ToolCancellationReason {
    if (!ctx.isObject(value)) return null;
    const code = ctx.getPropertyStr(value, "code");
    defer ctx.freeValue(code);
    if (ctx.hasException()) {
        pending.dropException(ctx);
        return null;
    }
    if (!ctx.isString(code)) return null;
    const text = ctx.toCStringLen(code) catch return null;
    defer ctx.freeCString(text.ptr);
    if (std.mem.eql(u8, text, "setup_declined")) return .setup_declined;
    if (std.mem.eql(u8, text, "setup_canceled")) return .setup_dismissed;
    return null;
}

fn stringifyValue(host: *Host, call: *table.Call, value: Value) void {
    const ctx = host.ctx;
    const json = ctx.jsonStringify(value, quickjs.UNDEFINED, quickjs.UNDEFINED);
    defer ctx.freeValue(json);
    if (!ctx.isString(json)) {
        pending.dropException(ctx);
        return settleText(host, call, "the tool answered a value that is not JSON", true);
    }
    const text = ctx.toCStringLen(json) catch {
        pending.dropException(ctx);
        return settleText(host, call, "the tool answered a value that is not JSON", true);
    };
    defer ctx.freeCString(text.ptr);
    settleText(host, call, text, false);
}

/// Read the text of a rejection. An Error carries `message`; any other value becomes a string.
fn errorText(ctx: Context, value: Value) ?[:0]const u8 {
    if (ctx.isObject(value)) {
        const message = ctx.getPropertyStr(value, "message");
        defer ctx.freeValue(message);
        if (ctx.isString(message)) {
            return ctx.toCStringLen(message) catch {
                pending.dropException(ctx);
                return null;
            };
        }
    }
    return ctx.toCStringLen(value) catch {
        pending.dropException(ctx);
        return null;
    };
}

/// Sanitize the answer as UTF-8 and wake the submitter.
fn settleText(host: *Host, call: *table.Call, text: []const u8, is_error: bool) void {
    call.settle(host.io, utf8.sanitize(host.gpa, text) catch unreachable, is_error);
}

fn settleTextAndView(host: *Host, call: *table.Call, text: []const u8, view_json: []const u8) void {
    call.settleView(host.io, utf8.sanitize(host.gpa, text) catch unreachable, utf8.sanitize(host.gpa, view_json) catch unreachable);
}

test "a settle after a spent interrupt slice still reads the answer" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const call = host.calls.submitHook("tool.before", "{}");
    call.state = .running;
    call.promise = try host.ctx.eval(
        \\Promise.resolve({ toJSON() { let n = 0; for (let i = 0; i < 100000; i += 1) n += i; return { ok: n > 0 }; } })
    , "answer.js", .{});
    // The last job of a drain can spend the slice right before the poll.
    host.interrupt_count = host.interrupt_budget;
    pollRunning(host);
    try std.testing.expect(call.state == .settled);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"ok\":true}", call.text.?);
    call.finish();
    try host.pump();
}

const support = @import("test_support.zig");
