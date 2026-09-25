//! The owner side of a tool or hook call: start the handler, poll its promise, and settle the record.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const table = @import("tools.zig");
const utf8 = @import("../utf8.zig");
const pending = @import("pending.zig");
const cancellation = @import("native/cancellation.zig");
const module = @import("native/module.zig");
const c = @import("quickjs_c");
const proto = @import("proto");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Abort the signal of every left call before any continuation can read it.
pub fn abortLeft(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (!call.submitter_done or !host.ctx.isObject(call.signal)) continue;
        cancellation.cancel(host, call.signal);
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

/// Answer every waiting call, so a turn task never sleeps past the host. `Host.close` calls this.
pub fn abortAll(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (host.ctx.isObject(call.signal)) {
            cancellation.cancel(host, call.signal);
        }
        if (call.state == .settled or call.submitter_done) continue;
        call.settle(host.io, null, null, true);
    }
}

/// Invoke the handler this call names and retain its promise until it settles.
fn start(host: *Host, call: *table.Call) void {
    switch (call.kind) {
        .tool => startTool(host, call),
        .hook => startHook(host, call),
    }
}

/// Parse the JSON the submitter wrote. A bad document settles the call and answers null.
fn parseArguments(host: *Host, call: *table.Call) ?Value {
    const text = host.gpa.dupeZ(u8, call.arguments) catch unreachable;
    defer host.gpa.free(text);
    const parsed = host.ctx.parseJSON(text, "call-arguments.json");
    if (!host.ctx.isException(parsed)) return parsed;
    pending.dropException(host.ctx);
    settleText(host, call, "the arguments are not valid JSON", null, true);
    return null;
}

/// Hand one point and its payload to the chain folder. The folder answers one Promise for the chain.
fn startHook(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    // A withdrawn folder answers no point, so the call proceeds rather than failing the round.
    const folder = host.hooks.dispatch orelse return settleText(host, call, "", null, false);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    const point = ctx.newString(call.name);
    if (ctx.isException(point)) {
        pending.dropException(ctx);
        return settleText(host, call, "out of memory", null, true);
    }
    defer ctx.freeValue(point);

    host.enterSlice();
    var argv = [_]Value{ point, parsed };
    const answer = ctx.call(folder, quickjs.UNDEFINED, &argv);
    acceptPromise(host, call, answer);
}

fn startTool(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const at = host.tools.find(call.name) orelse
        return settleText(host, call, "the tool is not registered", null, true);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    // The handler reads `signal.aborted` between its awaits, so a canceled turn can stop early.
    call.signal = cancellation.create(host);
    const context = ctx.newObject();
    if (!ctx.hasException()) {
        ctx.setPropertyStr(context, "workspaceRoot", ctx.newString(call.workspace_root)) catch {};
        if (call.site) |site| {
            const id = std.fmt.bytesToHex(site.session_id.raw, .lower);
            ctx.setPropertyStr(context, "sessionId", ctx.newString(&id)) catch {};
            ctx.setPropertyStr(context, "messageId", ctx.newInt64(@intCast(site.message_id))) catch {};
            ctx.setPropertyStr(context, "partId", ctx.newInt64(@intCast(site.part_id))) catch {};
        }
        // `output` is bound to this call by its signal, so it still works after a destructure.
        var data = [_]c.JSValue{call.signal};
        ctx.setPropertyStr(context, "output", c.JS_NewCFunctionData(ctx.ptr, jsOutput, 1, 0, 1, &data)) catch {};
    }
    // A full QuickJS heap fails the call, not the host, so the two roots go and the call settles.
    if (ctx.hasException()) {
        ctx.freeValue(context);
        ctx.freeValue(call.signal);
        call.signal = quickjs.UNDEFINED;
        pending.dropException(ctx);
        return settleText(host, call, "out of memory", null, true);
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
        }, null, true);
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
        const message = errorText(ctx, value);
        defer if (message) |text| ctx.freeCString(text.ptr);
        const fallback: []const u8 = switch (call.kind) {
            .tool => "the tool failed",
            .hook => "the hook failed",
        };
        return settleText(host, call, if (message) |text| text else fallback, null, true);
    }
    // An empty answer is the proceed decision for a hook, and empty output for a tool.
    if (ctx.isUndefined(value) or ctx.isNull(value)) return settleText(host, call, "", null, false);
    // A hook answers one object, which never carries model text or a view.
    if (call.kind != .tool) return stringifyValue(host, call, value);
    if (ctx.isString(value)) {
        const text = cstring(ctx, value) orelse return settleText(host, call, "the tool answered text the host cannot read", null, true);
        defer ctx.freeCString(text.ptr);
        return settleText(host, call, text, null, false);
    }

    if (ctx.isObject(value) and !ctx.isArray(value)) {
        const marker = ctx.getPropertyStr(value, "__yuke_result");
        defer ctx.freeValue(marker);
        const marked = ctx.isBool(marker) and (ctx.toBool(marker) catch false);
        if (!marked) return stringifyValue(host, call, value);
        const text_value = ctx.getPropertyStr(value, "text");
        defer ctx.freeValue(text_value);
        if (ctx.isString(text_value)) {
            const text = cstring(ctx, text_value) orelse return settleText(host, call, "the tool answered text the host cannot read", null, true);
            defer ctx.freeCString(text.ptr);
            // The extra object holds the view and the media, so a new member needs no host change.
            const extra_value = ctx.getPropertyStr(value, "extra");
            defer ctx.freeValue(extra_value);
            if (ctx.isUndefined(extra_value) or ctx.isNull(extra_value)) return settleText(host, call, text, null, false);
            const json = ctx.jsonStringify(extra_value, quickjs.UNDEFINED, quickjs.UNDEFINED);
            defer ctx.freeValue(json);
            if (!ctx.isString(json)) {
                pending.dropException(ctx);
                return settleText(host, call, "the tool answered a result that is not JSON", null, true);
            }
            const extra_text = cstring(ctx, json) orelse return settleText(host, call, "the tool answered a result that is not JSON", null, true);
            defer ctx.freeCString(extra_text.ptr);
            return settleText(host, call, text, extra_text, false);
        }
    }

    return stringifyValue(host, call, value);
}

/// Take one chunk of live output for the call the signal names. A call that ended drops it, and the stream cap bounds it.
fn jsOutput(ctx_ptr: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue, _: c_int, data: [*c]c.JSValue) callconv(.c) c.JSValue {
    const ctx: Context = .{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("output needs a string");
    const text = module.string(ctx, argv[0]) orelse return ctx.throwTypeError("output needs a string");
    defer ctx.freeCString(text.ptr);
    const host = Host.fromContext(ctx);
    const call = host.calls.callForSignal(ctx, data[0]) orelse return quickjs.UNDEFINED;
    const kept = utf8.floor(text, call.output_room);
    call.output_room = if (kept < text.len) 0 else call.output_room - kept;
    if (kept == 0) return quickjs.UNDEFINED;
    call.output.appendSlice(host.gpa, text[0..kept]) catch unreachable;
    call.changed.set(host.io);
    return quickjs.UNDEFINED;
}

fn stringifyValue(host: *Host, call: *table.Call, value: Value) void {
    const ctx = host.ctx;
    const json = ctx.jsonStringify(value, quickjs.UNDEFINED, quickjs.UNDEFINED);
    defer ctx.freeValue(json);
    if (!ctx.isString(json)) {
        pending.dropException(ctx);
        return settleText(host, call, "the tool answered a value that is not JSON", null, true);
    }
    const text = cstring(ctx, json) orelse return settleText(host, call, "the tool answered a value that is not JSON", null, true);
    defer ctx.freeCString(text.ptr);
    settleText(host, call, text, null, false);
}

/// Read the text of a rejection. An Error carries `message`; any other value becomes a string.
fn errorText(ctx: Context, value: Value) ?[:0]const u8 {
    if (ctx.isObject(value)) {
        const message = ctx.getPropertyStr(value, "message");
        defer ctx.freeValue(message);
        if (ctx.isString(message)) {
            return cstring(ctx, message);
        }
    }
    return cstring(ctx, value);
}

fn cstring(ctx: Context, value: Value) ?[:0]const u8 {
    return ctx.toCStringLen(value) catch {
        pending.dropException(ctx);
        return null;
    };
}

/// Sanitize the answer and its extra JSON as UTF-8 and wake the submitter.
fn settleText(host: *Host, call: *table.Call, text: []const u8, extra_json: ?[]const u8, is_error: bool) void {
    if (host.ctx.isObject(call.signal)) cancellation.cancel(host, call.signal);
    const extra = if (extra_json) |json| utf8.sanitize(host.gpa, json) catch unreachable else null;
    call.settle(host.io, utf8.sanitize(host.gpa, text) catch unreachable, extra, is_error);
}

const support = @import("tests/support.zig");

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
    pump(host);
    try std.testing.expect(call.state == .settled);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"ok\":true}", call.text.?);
    call.finish();
    try host.pump();
}

test "a tool signal aborts at settlement before its submitter leaves" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { defineTool } from "yuke:internal/native/tools";
        \\defineTool("probe", { description: "Probe", parameters: { type: "object", properties: {} }, execute: async (_, signal) => { await 0; globalThis.signal = signal; return "ok"; } });
    , "settled-signal.js");
    const invocation = host.calls.submit("probe", "{}", "");
    try host.pump();
    try std.testing.expect(invocation.state == .settled);
    try std.testing.expect(!invocation.submitter_done);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.signal.aborted"));
    try support.dropCall(host, invocation);
}
