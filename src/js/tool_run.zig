//! The owner side of a tool or hook call: start the handler, poll its promise, and settle the record.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("host.zig").Host;
const table = @import("tools.zig");
const toolset = @import("../engine/toolset.zig");
const hookset = @import("../engine/hookset.zig");
const utf8 = @import("../utf8.zig");
const pending = @import("pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Start queued calls and poll running calls after the owner drains jobs.
pub fn pump(host: *Host) void {
    // A start can queue nothing new, so one pass over the list visits every call exactly once.
    for (host.calls.live.items) |call| switch (call.state) {
        .queued => if (!call.submitter_done) start(host, call),
        .running => if (!call.submitter_done) poll(host, call),
        .settled => {},
    };
    host.calls.sweep(host.ctx);
}

/// Answer every waiting call, so a turn task never sleeps past the host. `Host.close` calls this.
pub fn abortAll(host: *Host) void {
    for (host.calls.live.items) |call| {
        if (call.state == .settled or call.submitter_done) continue;
        call.settle(null, true);
    }
}

/// Invoke the handler this call names and retain its promise until it settles.
fn start(host: *Host, call: *table.Call) void {
    switch (call.kind) {
        .tool => startTool(host, call),
        .hook => startHook(host, call),
    }
}

/// Hand one point and its payload to the chain folder. The folder answers one Promise for the chain.
fn startHook(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    // A withdrawn folder answers no point, so the call proceeds rather than failing the round.
    const folder = host.hooks.dispatch orelse return settleText(host, call, "", false);

    const payload = host.gpa.dupeZ(u8, call.arguments) catch unreachable;
    defer host.gpa.free(payload);
    const parsed = ctx.parseJSON(payload, "hook-payload.json");
    if (ctx.isException(parsed)) {
        pending.dropException(ctx);
        return settleText(host, call, "the hook payload is not valid JSON", true);
    }
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
    if (ctx.isException(answer)) {
        const exc = ctx.getException();
        defer ctx.freeValue(exc);
        return settleValue(host, call, exc, true);
    }
    if (!ctx.isPromise(answer)) {
        ctx.freeValue(answer);
        return settleText(host, call, "the hook dispatcher must return a Promise", true);
    }
    call.promise = answer; // the call holds the root until it settles
    call.state = .running;
    poll(host, call);
}

fn startTool(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const at = host.tools.find(call.name) orelse
        return settleText(host, call, "the tool is not registered", true);

    const args = host.gpa.dupeZ(u8, call.arguments) catch unreachable;
    defer host.gpa.free(args);
    const parsed = ctx.parseJSON(args, "tool-arguments.json");
    if (ctx.isException(parsed)) {
        pending.dropException(ctx);
        return settleText(host, call, "the arguments are not valid JSON", true);
    }
    defer ctx.freeValue(parsed);

    // The handler reads `signal.aborted` between its awaits, so a canceled turn can stop early.
    call.signal = ctx.newObject();
    const context = ctx.newObject();
    if (!ctx.hasException()) {
        ctx.setPropertyStr(call.signal, "aborted", quickjs.FALSE) catch {};
        ctx.setPropertyStr(context, "workspaceRoot", ctx.newString(call.workspace_root)) catch {};
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
    const answer = ctx.call(host.tools.handlers.items[at], quickjs.UNDEFINED, &argv);
    if (ctx.isException(answer)) {
        const exc = ctx.getException();
        defer ctx.freeValue(exc);
        return settleValue(host, call, exc, true);
    }
    if (!ctx.isPromise(answer)) {
        ctx.freeValue(answer);
        return settleText(host, call, "the tool execute function must return a Promise", true);
    }
    call.promise = answer; // the call holds the root until it settles
    call.state = .running;
    poll(host, call);
}

/// Read one Promise. A pending Promise stays; the owner asks again after the next job drain.
fn poll(host: *Host, call: *table.Call) void {
    const ctx = host.ctx;
    const state = ctx.promiseState(call.promise);
    if (state == .Pending) return;
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
        const fallback = if (call.kind == .hook) "the hook failed" else "the tool failed";
        return settleText(host, call, if (message) |text| text else fallback, true);
    }
    // An empty answer is the proceed decision for a hook, and empty output for a tool.
    if (ctx.isUndefined(value) or ctx.isNull(value)) return settleText(host, call, "", false);
    // A hook answers one decision object, which never carries model text or a view.
    if (call.kind == .hook) return stringifyValue(host, call, value);
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
    call.settle(utf8.sanitize(host.gpa, text) catch unreachable, is_error);
}

fn settleTextAndView(host: *Host, call: *table.Call, text: []const u8, view_json: []const u8) void {
    call.settleView(utf8.sanitize(host.gpa, text) catch unreachable, utf8.sanitize(host.gpa, view_json) catch unreachable);
}
