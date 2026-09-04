//! A turn queues an async JavaScript tool call and the sole QuickJS owner pumps it to completion.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("host.zig").Host;
const table = @import("tools.zig");
const ir = @import("ai").ir;
const toolset = @import("../engine/toolset.zig");
const hookset = @import("../engine/hookset.zig");
const utf8 = @import("../utf8.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Build the port the process installs. The set answers from the live host table.
pub fn toolSet(host: *Host) toolset.ToolSet {
    std.debug.assert(host.phase == .open);
    return .{ .ctx = host, .getDecls = declsFor, .run = runFor };
}

/// Answer the live declarations. The engine holds them only until it writes one request body.
fn declsFor(ctx: *anyopaque) []const ir.Tool {
    const host: *Host = @ptrCast(@alignCast(ctx));
    return host.tools.decls.items;
}

/// Submit one call and wait at the turn cancellation point for the owner to answer it.
fn runFor(ctx: *anyopaque, out: std.mem.Allocator, name: []const u8, arguments: []const u8, workspace_root: []const u8) toolset.Outcome {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const call = host.calls.submitAt(name, arguments, workspace_root) catch return fault(out, "the host cannot queue another tool call");
    // The owner sweeps the record, so leaving is the last thing this task does with it.
    defer {
        host.calls.finish(call);
        if (host.owner_wake) |wake| wake.set();
    }
    // The owner sleeps between frames, so a queued call must wake it.
    if (host.owner_wake) |wake| wake.set();

    call.done.wait() catch return fault(out, "cancellation stopped the tool call");
    std.debug.assert(call.state == .settled); // the owner sets the event once, and only on a settle
    const text = call.text orelse "the tool call did not finish";
    const view = if (call.view_json) |json|
        std.json.parseFromSliceLeaky([]proto.view.View, out, json, .{}) catch
            return fault(out, "the tool answered an invalid view")
    else
        null;
    return .{
        .output = out.dupe(u8, text) catch return fault(out, "out of memory"),
        .view = view,
        .is_error = call.is_error,
    };
}

/// Build the hook port the process installs. The set answers from the live host table.
pub fn hookSet(host: *Host) hookset.HookSet {
    std.debug.assert(host.phase == .open);
    return .{ .ctx = host, .holds = holdsFor, .ask = askFor };
}

/// Report whether a handler waits. A turn task reads the point set and enters no JavaScript.
fn holdsFor(ctx: *anyopaque, point: proto.hook.Point) bool {
    const host: *Host = @ptrCast(@alignCast(ctx));
    return host.hooks.holds(point);
}

/// Submit one point and wait for the folded chain. A handler fault proceeds, because it is a bug.
fn askFor(ctx: *anyopaque, out: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) hookset.Decision {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const call = host.calls.submitHook(point.wireName(), payload) catch return .proceed;
    // The owner sweeps the record, so leaving is the last thing this task does with it.
    defer {
        host.calls.finish(call);
        if (host.owner_wake) |wake| wake.set();
    }
    // The owner sleeps between frames, so a queued call must wake it.
    if (host.owner_wake) |wake| wake.set();

    call.done.wait() catch return .proceed;
    std.debug.assert(call.state == .settled); // the owner sets the event once, and only on a settle
    const text = call.text orelse return .proceed;
    if (call.is_error) {
        std.log.warn("hook {s} faulted: {s}", .{ point.wireName(), text });
        return .proceed;
    }
    if (text.len == 0) return .proceed;
    return decisionOf(out, point, text);
}

/// Read the decision the chain answered. Text the point cannot describe proceeds.
fn decisionOf(out: std.mem.Allocator, point: proto.hook.Point, text: []const u8) hookset.Decision {
    const parsed = std.json.parseFromSliceLeaky(proto.hook.Decision, out, text, .{}) catch {
        std.log.warn("hook {s} answered an unreadable decision", .{point.wireName()});
        return .proceed;
    };
    return switch (parsed) {
        .proceed => .proceed,
        .replace => |value| .{ .replace = std.json.Stringify.valueAlloc(out, value, .{}) catch return .proceed },
        .block => |blocked| .{ .block = out.dupe(u8, blocked.reason) catch return .proceed },
    };
}

fn fault(out: std.mem.Allocator, message: []const u8) toolset.Outcome {
    return .{ .output = out.dupe(u8, message) catch message, .is_error = true };
}

/// Start queued calls and poll running calls after the owner drains jobs.
pub fn pump(host: *Host) void {
    std.debug.assert(host.phase != .destroyed);
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

    const payload = host.gpa.dupeZ(u8, call.arguments) catch
        return settleText(host, call, "out of memory", true);
    defer host.gpa.free(payload);
    const parsed = ctx.parseJSON(payload, "hook-payload.json");
    if (ctx.isException(parsed)) {
        dropException(ctx);
        return settleText(host, call, "the hook payload is not valid JSON", true);
    }
    defer ctx.freeValue(parsed);

    const point = ctx.newString(call.name);
    if (ctx.isException(point)) {
        dropException(ctx);
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
    const tool = host.tools.find(call.name) orelse
        return settleText(host, call, "the tool is not registered", true);

    const args = host.gpa.dupeZ(u8, call.arguments) catch
        return settleText(host, call, "out of memory", true);
    defer host.gpa.free(args);
    const parsed = ctx.parseJSON(args, "tool-arguments.json");
    if (ctx.isException(parsed)) {
        dropException(ctx);
        return settleText(host, call, "the arguments are not valid JSON", true);
    }
    defer ctx.freeValue(parsed);

    // The handler reads `signal.aborted` between its awaits, so a canceled turn can stop early.
    call.signal = ctx.newObject();
    if (ctx.isException(call.signal)) {
        call.signal = quickjs.UNDEFINED;
        dropException(ctx);
        return settleText(host, call, "out of memory", true);
    }
    ctx.setPropertyStr(call.signal, "aborted", quickjs.FALSE) catch {
        dropException(ctx);
        return settleText(host, call, "out of memory", true);
    };

    host.enterSlice();
    const context = ctx.newObject();
    if (ctx.isException(context)) {
        dropException(ctx);
        return settleText(host, call, "out of memory", true);
    }
    const root = ctx.newString(call.workspace_root);
    if (ctx.isException(root)) {
        ctx.freeValue(context);
        dropException(ctx);
        return settleText(host, call, "out of memory", true);
    }
    ctx.setPropertyStr(context, "workspaceRoot", root) catch {
        ctx.freeValue(context);
        dropException(ctx);
        return settleText(host, call, "out of memory", true);
    };
    defer ctx.freeValue(context);
    var argv = [_]Value{ parsed, call.signal, context };
    const answer = ctx.call(tool.handler, quickjs.UNDEFINED, &argv);
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
            dropException(ctx);
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
                dropException(ctx);
                return settleText(host, call, "the tool answered text the host cannot read", true);
            };
            defer ctx.freeCString(text.ptr);
            const view_value = ctx.getPropertyStr(value, "view");
            defer ctx.freeValue(view_value);
            if (ctx.isUndefined(view_value) or ctx.isNull(view_value)) return settleText(host, call, text, false);
            const json = ctx.jsonStringify(view_value, quickjs.UNDEFINED, quickjs.UNDEFINED);
            defer ctx.freeValue(json);
            if (!ctx.isString(json)) {
                dropException(ctx);
                return settleText(host, call, "the tool answered a view that is not JSON", true);
            }
            const view_text = ctx.toCStringLen(json) catch {
                dropException(ctx);
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
        dropException(ctx);
        return settleText(host, call, "the tool answered a value that is not JSON", true);
    }
    const text = ctx.toCStringLen(json) catch {
        dropException(ctx);
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
                dropException(ctx);
                return null;
            };
        }
    }
    return ctx.toCStringLen(value) catch {
        dropException(ctx);
        return null;
    };
}

/// Sanitize the answer as UTF-8 and wake the submitter.
fn settleText(host: *Host, call: *table.Call, text: []const u8, is_error: bool) void {
    const owned = utf8.sanitize(host.gpa, text) catch {
        call.settle(null, true);
        return;
    };
    call.settle(owned, is_error);
}

fn settleTextAndView(host: *Host, call: *table.Call, text: []const u8, view_json: []const u8) void {
    const owned_text = utf8.sanitize(host.gpa, text) catch {
        call.settle(null, true);
        return;
    };
    errdefer host.gpa.free(owned_text);
    const owned_view = utf8.sanitize(host.gpa, view_json) catch {
        call.settle(null, true);
        return;
    };
    call.settleView(owned_text, owned_view);
}

fn dropException(ctx: Context) void {
    if (ctx.hasException()) ctx.freeValue(ctx.getException());
}
