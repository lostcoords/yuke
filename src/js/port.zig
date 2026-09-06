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
    return .{ .ctx = host, .getDecls = declsFor, .isAllowed = isAllowed, .run = runFor };
}

/// Answer the live declarations. The engine holds them only until it writes one request body.
fn declsFor(ctx: *anyopaque, arena: std.mem.Allocator, selection: toolset.Selection) error{OutOfMemory}![]const ir.Tool {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const decls = try arena.alloc(ir.Tool, host.tools.entries.items.len);
    var at: usize = 0;
    for (host.tools.entries.items) |entry| {
        if (!selection.can_spawn and entry.spawns_agents) continue;
        decls[at] = try proto.dupe(arena, entry.decl);
        at += 1;
    }
    return decls[0..at];
}

fn isAllowed(ctx: *anyopaque, name: []const u8, selection: toolset.Selection) bool {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const index = host.tools.find(name) orelse return true;
    return selection.can_spawn or !host.tools.entries.items[index].spawns_agents;
}

/// Submit one call and wait at the turn cancellation point for the owner to answer it.
fn runFor(ctx: *anyopaque, out: std.mem.Allocator, name: []const u8, arguments: []const u8, context: toolset.Context) toolset.Outcome {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const call = host.calls.submit(name, arguments, context.workspace_root);
    call.site = context.site;
    call.work = context.work;
    defer finishCall(host, call);
    awaitCall(host, call) catch return fault(out, "cancellation stopped the tool call");
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
        .cancellation_reason = call.cancellation_reason,
    };
}

fn awaitCall(host: *Host, call: *@import("tools.zig").Call) error{Canceled}!void {
    host.wake.set(host.io);
    try call.done.wait(host.io);
    std.debug.assert(call.state == .settled);
}

fn finishCall(host: *Host, call: *@import("tools.zig").Call) void {
    call.finish();
    host.wake.set(host.io);
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
    defer finishCall(host, call);
    awaitCall(host, call) catch return .canceled;
    if (host.phase != .open) return .canceled;
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
    const parsed = std.json.parseFromSliceLeaky(proto.hook.Decision, out, text, .{ .allocate = .alloc_always }) catch {
        std.log.warn("hook {s} answered an unreadable decision", .{point.wireName()});
        return .proceed;
    };
    return switch (parsed) {
        .proceed => .proceed,
        .replace => |replaced| .{ .replace = replaced.value },
        .block => |blocked| .{ .block = blocked.reason },
    };
}

fn fault(out: std.mem.Allocator, message: []const u8) toolset.Outcome {
    return .{ .output = out.dupe(u8, message) catch message, .is_error = true };
}

test "hook decisions own text after the call answer leaves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out = arena.allocator();

    const blocked_text = try std.testing.allocator.dupe(u8, "{\"type\":\"block\",\"reason\":\"denied\"}");
    const blocked = decisionOf(out, .@"input.before", blocked_text);
    std.testing.allocator.free(blocked_text);
    try std.testing.expect(blocked == .block);
    try std.testing.expectEqualStrings("denied", blocked.block);

    const replaced_text = try std.testing.allocator.dupe(u8, "{\"type\":\"replace\",\"value\":{\"name\":\"bash\"}}");
    const replaced = decisionOf(out, .@"tool.before", replaced_text);
    std.testing.allocator.free(replaced_text);
    try std.testing.expect(replaced == .replace);
    try std.testing.expectEqualStrings("bash", replaced.replace.object.get("name").?.string);
}
