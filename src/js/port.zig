//! The turn-task side of a tool or hook call: submit the record, wake the owner, and wait for the answer.

const std = @import("std");
const proto = @import("proto");
const Host = @import("host.zig").Host;
const ir = @import("ai").ir;
const toolset = @import("../engine/toolset.zig");
const hookset = @import("../engine/hookset.zig");

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
    const call = host.calls.submit(name, arguments, workspace_root);
    // The owner sweeps the record, so leaving is the last thing this task does with it.
    defer {
        call.finish();
        host.wake.set();
    }
    // The owner sleeps between frames, so a queued call must wake it.
    host.wake.set();

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
    const call = host.calls.submitHook(point.wireName(), payload);
    // The owner sweeps the record, so leaving is the last thing this task does with it.
    defer {
        call.finish();
        host.wake.set();
    }
    // The owner sleeps between frames, so a queued call must wake it.
    host.wake.set();

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
        .replace => |replaced| .{ .replace = std.json.Stringify.valueAlloc(out, replaced.value, .{}) catch return .proceed },
        .block => |blocked| .{ .block = out.dupe(u8, blocked.reason) catch return .proceed },
    };
}

fn fault(out: std.mem.Allocator, message: []const u8) toolset.Outcome {
    return .{ .output = out.dupe(u8, message) catch message, .is_error = true };
}
