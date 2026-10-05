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
    for (host.calls.live.items) |call| switch (call.state) {
        .detached, .dropped, .left => if (call.signal()) |signal| cancellation.cancel(host, signal),
        .queued, .running, .settled => {},
    };
}

/// Start queued calls and poll running calls after the owner drains jobs.
pub fn pump(host: *Host) void {
    // A start can queue nothing new, so one pass over the list visits every call exactly once.
    for (host.calls.live.items) |call| switch (call.state) {
        .queued => switch (call.kind) {
            .tool => startTool(host, call),
            .hook => startHook(host, call),
        },
        .running => poll(host, call),
        .settled, .detached, .dropped, .left => {},
    };
    abortLeft(host);
    host.calls.sweep(host.ctx);
}

/// Answer every waiting call, so a turn task never sleeps past the host. `Host.close` calls this.
pub fn abortAll(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (call.signal()) |signal| cancellation.cancel(host, signal);
        switch (call.state) {
            .queued => {},
            .running => |promise| host.ctx.freeValue(promise),
            .settled, .detached, .dropped, .left => continue,
        }
        call.settle(host.io, .closed);
    }
}

/// Parse the JSON the submitter wrote. A bad document settles the call and answers null.
fn parseArguments(host: *Host, call: *table.Call) ?Value {
    const text = host.gpa.dupeZ(u8, call.arguments) catch @panic("out of memory");
    defer host.gpa.free(text);
    const parsed = host.ctx.parseJSON(text, "call-arguments.json");
    if (!host.ctx.isException(parsed)) return parsed;
    pending.dropException(host.ctx);
    settleText(host, call, "the arguments are not valid JSON", .failed);
    return null;
}

/// Hand one point and its payload to the chain folder. The folder answers one Promise for the chain.
fn startHook(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    // A withdrawn folder answers no point, so the call proceeds rather than failing the round.
    const folder = host.hooks.dispatch orelse return settleText(host, call, "", .text);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    const point = ctx.newString(call.name);
    if (ctx.isException(point)) {
        pending.dropException(ctx);
        return settleText(host, call, "out of memory", .failed);
    }
    defer ctx.freeValue(point);

    host.enterSlice();
    var argv = [_]Value{ point, parsed };
    const answer = ctx.call(folder, quickjs.UNDEFINED, &argv);
    acceptPromise(host, call, answer);
}

fn startTool(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    // The registration that the run advertised runs, so a later tool with the same name never stands in for it.
    const at = host.tools.findRegistration(call.name, call.kind.tool.id) orelse
        return settleText(host, call, "the tool is not registered", .failed);
    const parsed = parseArguments(host, call) orelse return;
    defer ctx.freeValue(parsed);

    // The handler can read `signal.aborted` between its awaits, so a canceled turn can stop early.
    const tool = &call.kind.tool;
    const signal = cancellation.create(host);
    tool.signal = signal;
    const context = ctx.newObject();
    if (!ctx.hasException()) {
        ctx.setPropertyStr(context, "workspaceRoot", ctx.newString(tool.workspace_root)) catch {};
        const id = std.fmt.bytesToHex(tool.site.session_id.raw, .lower);
        ctx.setPropertyStr(context, "sessionId", ctx.newString(&id)) catch {};
        ctx.setPropertyStr(context, "messageId", ctx.newInt64(@intCast(tool.site.message_id))) catch {};
        ctx.setPropertyStr(context, "partId", ctx.newInt64(@intCast(tool.site.part_id))) catch {};
        // `output` is bound to this call by its signal, so it still works after a destructure.
        var data = [_]c.JSValue{signal};
        ctx.setPropertyStr(context, "output", c.JS_NewCFunctionData(ctx.ptr, jsOutput, 1, 0, 1, &data)) catch {};
    }
    // A full QuickJS heap fails the call, not the host, so the two roots go and the call settles.
    if (ctx.hasException()) {
        ctx.freeValue(context);
        ctx.freeValue(signal);
        tool.signal = null;
        pending.dropException(ctx);
        return settleText(host, call, "out of memory", .failed);
    }
    defer ctx.freeValue(context);
    host.enterSlice();
    var argv = [_]Value{ parsed, signal, context };
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
        }, .failed);
    }
    // The call owns the Promise, so the rejection tracker never reports it, even after the submitter leaves.
    c.JS_PromiseMarkAsHandled(ctx.ptr, answer);
    call.state = .{ .running = answer }; // the call holds the root until it settles or the sweep frees it
    poll(host, call);
}

/// Read one Promise. A pending Promise stays.
fn poll(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const promise = call.state.running;
    const state = ctx.promiseState(promise);
    if (state == .Pending) return;
    defer ctx.freeValue(promise);
    // A settle can run a user `toJSON` or getter, so it starts a fresh interrupt slice.
    host.enterSlice();
    const result = ctx.promiseResult(promise);
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
        return settleText(host, call, if (message) |text| text else fallback, .failed);
    }
    if (call.kind == .hook) {
        // An undefined answer is the proceed decision.
        if (ctx.isUndefined(value)) return settleText(host, call, "", .text);
        return stringifyValue(host, call, value, .text);
    }
    if (ctx.isString(value)) {
        const text = cstring(ctx, value) orelse return settleText(host, call, "the tool answered text the host cannot read", .failed);
        defer ctx.freeCString(text.ptr);
        return settleText(host, call, text, .text);
    }
    // The submitter decodes the object as a `ToolOutcome`, so it checks every key in one place.
    if (ctx.isObject(value) and !ctx.isArray(value)) return stringifyValue(host, call, value, .outcome);
    settleText(host, call, "the tool answered a value that is not a string or a ToolOutcome", .failed);
}

/// Take one chunk of live output for the call the signal names. A call that ended drops it, and the stream cap bounds it.
fn jsOutput(ctx_ptr: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue, _: c_int, data: [*c]c.JSValue) callconv(.c) c.JSValue {
    const ctx: Context = .{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("output needs a string");
    const text = module.string(ctx, argv[0]) orelse return ctx.throwTypeError("output needs a string");
    defer ctx.freeCString(text.ptr);
    const host = Host.fromContext(ctx);
    const call = host.calls.callForSignal(ctx, data[0]) orelse return quickjs.UNDEFINED;
    const tool = &call.kind.tool; // only a tool call holds a signal
    const kept = utf8.floor(text, tool.output_room);
    tool.output_room = if (kept < text.len) 0 else tool.output_room - kept;
    if (kept == 0) return quickjs.UNDEFINED;
    tool.output.appendSlice(host.gpa, text[0..kept]) catch @panic("out of memory");
    call.wake.set(host.io);
    return quickjs.UNDEFINED;
}

fn stringifyValue(host: *Host, call: *table.Call, value: Value, kind: Kind) void {
    const ctx = host.ctx;
    const json = ctx.jsonStringify(value, quickjs.UNDEFINED, quickjs.UNDEFINED);
    defer ctx.freeValue(json);
    if (!ctx.isString(json)) {
        pending.dropException(ctx);
        return settleText(host, call, "the tool answered a value that is not JSON", .failed);
    }
    const text = cstring(ctx, json) orelse return settleText(host, call, "the tool answered a value that is not JSON", .failed);
    defer ctx.freeCString(text.ptr);
    settleText(host, call, text, kind);
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

/// The submitter reads settled text as model text, a `ToolOutcome` JSON object, or an error.
const Kind = enum { text, outcome, failed };

/// Sanitize the answer as UTF-8 and wake the submitter.
fn settleText(host: *Host, call: *table.Call, text: []const u8, kind: Kind) void {
    std.debug.assert(kind != .outcome or call.kind == .tool); // only a tool answers a ToolOutcome
    if (call.signal()) |signal| cancellation.cancel(host, signal);
    const owned = utf8.sanitize(host.gpa, text) catch @panic("out of memory");
    call.settle(host.io, switch (kind) {
        .text => .{ .ok = .{ .text = owned } },
        .outcome => .{ .ok = .{ .text = owned, .outcome = true } },
        .failed => .{ .failed = owned },
    });
}

const support = @import("tests/support.zig");

test "a settle after a spent interrupt slice still reads the answer" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const call = host.calls.submitHook("tool.before", "{}");
    call.state = .{ .running = try host.ctx.eval(
        \\Promise.resolve({ toJSON() { let n = 0; for (let i = 0; i < 100000; i += 1) n += i; return { ok: n > 0 }; } })
    , "answer.js", .{}) };
    // The last job of a drain can spend the slice right before the poll.
    host.interrupt_count = host.interrupt_budget;
    pump(host);
    try std.testing.expect(!support.reply(call).is_error);
    try std.testing.expectEqualStrings("{\"ok\":true}", support.reply(call).text);
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
    const invocation = support.submitTool(host, "probe", "{}", support.toolContext(""));
    try host.pump();
    try std.testing.expect(invocation.state == .settled);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.signal.aborted"));
    try support.dropCall(host, invocation);
}

test "a call runs the registration its run resolved, never a newer one with the same name" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { defineTool } from "yuke:internal/native/tools";
        \\globalThis.old = defineTool("swap", { description: "Old", parameters: { type: "object", properties: {} }, execute: async () => "old" });
    , "swap-old.js");
    var context = support.toolContext("");
    context.tool = host.tools.entries.items[host.tools.find("swap").?].id;
    try host.evalModule(
        \\import { defineTool, removeTool } from "yuke:internal/native/tools";
        \\removeTool(globalThis.old);
        \\defineTool("swap", { description: "New", parameters: { type: "object", properties: {} }, execute: async () => "new" });
    , "swap-new.js");
    const call = host.calls.submit("swap", "{}", context);
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(support.reply(call).is_error);
    try std.testing.expectEqualStrings("the tool is not registered", support.reply(call).text);
    try support.dropCall(host, call);
}

test "a call runs the variant or the global tool that its id names" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { defineTool } from "yuke:internal/native/tools";
        \\const parameters = { type: "object", properties: {} };
        \\globalThis.variant = defineTool("pick", { description: "Variant", parameters, when: () => true, execute: async () => "variant" });
        \\globalThis.global = defineTool("pick", { description: "Global", parameters, execute: async () => "global" });
    , "pick.js");
    for ([_]struct { [:0]const u8, []const u8 }{ .{ "globalThis.variant", "variant" }, .{ "globalThis.global", "global" } }) |case| {
        var context = support.toolContext("");
        context.tool = @intCast(try host.evalInt(case[0]));
        const call = host.calls.submit("pick", "{}", context);
        try support.pumpUntilSettled(host, call);
        try std.testing.expectEqualStrings(case[1], support.reply(call).text);
        try support.dropCall(host, call);
    }
}
