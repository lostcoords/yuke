//! The turn-task side of a tool or hook call: submit the record, wake the owner, and wait for the answer.

const std = @import("std");
const proto = @import("proto");
const Host = @import("host.zig").Host;
const ir = @import("ai").ir;
const toolset = @import("../engine/toolset.zig");
const hookset = @import("../engine/hookset.zig");
const tools = @import("tools.zig");

/// Build the port the process installs. The set answers from the live host table.
pub fn toolSet(host: *Host) toolset.ToolSet {
    std.debug.assert(host.phase == .open);
    return .{ .ctx = host, .decls = declsFor, .run = runFor };
}

/// Answer every declaration in table order, which is sorted, so the advertised order never follows load order.
fn declsFor(ctx: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]const ir.Tool {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const decls = try arena.alloc(ir.Tool, host.tools.entries.items.len);
    for (host.tools.entries.items, decls) |entry, *decl| decl.* = try proto.dupe(arena, entry.decl);
    return decls;
}

/// Submit one call and wait at the turn cancellation point for the owner to answer it.
fn runFor(ctx: *anyopaque, out: std.mem.Allocator, name: []const u8, arguments: []const u8, context: toolset.Context) toolset.Outcome {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const call = host.calls.submit(name, arguments, context.workspace_root);
    call.site = context.site;
    call.work = context.work;
    defer finishCall(host, call);
    host.wake.set(host.io);
    // Publish each output chunk while the tool runs, and the last one before the result.
    while (true) {
        call.changed.wait(host.io) catch return fault(out, "cancellation stopped the tool call");
        call.changed.reset();
        if (call.output.items.len != 0) {
            // Move the chunk out before the sink publishes it.
            var chunk = call.output;
            call.output = .empty;
            defer chunk.deinit(host.gpa);
            context.output.write(context.output.ctx, chunk.items);
        }
        if (call.state == .settled) break;
    }
    const text = call.text orelse "the tool call did not finish";
    const extra = if (call.extra_json) |json|
        extraOf(out, json) orelse return fault(out, "the tool answered an invalid view or media list")
    else
        Extra{};
    return .{
        .output = out.dupe(u8, text) catch unreachable,
        .view = extra.view,
        .media = extra.media,
        .tools_added = extra.tools_added,
        .is_error = call.is_error,
    };
}

fn awaitCall(host: *Host, call: *tools.Call) error{Canceled}!void {
    host.wake.set(host.io);
    try call.done.wait(host.io);
    std.debug.assert(call.state == .settled);
}

fn finishCall(host: *Host, call: *tools.Call) void {
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

/// Submit one point and wait for the folded chain. A failed dispatch or an unreadable answer blocks, so a bug never lets an action through.
fn askFor(ctx: *anyopaque, out: std.mem.Allocator, point: proto.hook.Point, payload: []const u8) hookset.Decision {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const call = host.calls.submitHook(point.wireName(), payload);
    defer finishCall(host, call);
    awaitCall(host, call) catch return .canceled;
    if (host.phase != .open) return .canceled;
    return answerOf(out, point, call);
}

/// Read the answer of one settled hook call into `out`. A fault or an unreadable answer blocks.
pub fn answerOf(out: std.mem.Allocator, point: proto.hook.Point, call: *const tools.Call) hookset.Decision {
    std.debug.assert(call.state == .settled);
    const text = call.text orelse return .proceed;
    if (call.is_error) {
        std.log.warn("hook {s} faulted: {s}", .{ point.wireName(), text });
        return .{ .block = "the hook dispatch failed" };
    }
    if (text.len == 0) return .proceed;
    return decisionOf(out, point, text);
}

/// Read the decision the chain answered. Text the point cannot describe proceeds.
fn decisionOf(out: std.mem.Allocator, point: proto.hook.Point, text: []const u8) hookset.Decision {
    const parsed = std.json.parseFromSliceLeaky(proto.hook.Decision, out, text, .{ .allocate = .alloc_always }) catch {
        std.log.warn("hook {s} answered an unreadable decision", .{point.wireName()});
        return .{ .block = "the hook answered an unreadable decision" };
    };
    return switch (parsed) {
        .proceed => .proceed,
        .replace => |replaced| .{ .replace = replaced.value },
        .block => |blocked| .{ .block = blocked.reason },
    };
}

/// The structured part of a builtin result. The engine admits the media before it commits the part.
const Extra = struct {
    view: ?[]const proto.view.View = null,
    media: []const proto.content.MediaBlob = &.{},
    tools_added: []const proto.tool.ToolDefinition = &.{},
};

/// Copy every string into `out`, because the owner frees the call JSON on its next sweep.
fn extraOf(out: std.mem.Allocator, json: []const u8) ?Extra {
    return std.json.parseFromSliceLeaky(Extra, out, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn fault(out: std.mem.Allocator, message: []const u8) toolset.Outcome {
    return .{ .output = out.dupe(u8, message) catch message, .is_error = true };
}

test "a tool result owns its view and media after the call answer leaves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json = try std.testing.allocator.dupe(u8, "{\"view\":[{\"type\":\"text\",\"text\":\"body\"}],\"media\":[{\"hash\":\"" ++ "ab" ** 32 ++ "\",\"mime\":\"image/png\",\"bytes\":3}]}");
    const extra = extraOf(arena.allocator(), json).?;
    @memset(json, 'x');
    std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("body", extra.view.?[0].text.text);
    try std.testing.expectEqualStrings("image/png", extra.media[0].mime);
    try std.testing.expectEqual(@as(u64, 3), extra.media[0].bytes);
    try std.testing.expect(extraOf(arena.allocator(), "{\"media\":[{\"hash\":\"zz\"}]}") == null);
    const found = extraOf(arena.allocator(), "{\"tools_added\":[{\"name\":\"mcp_read\",\"description\":\"Read.\",\"input_schema\":\"{}\"}]}").?;
    try std.testing.expectEqualStrings("mcp_read", found.tools_added[0].name);
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

    try std.testing.expect(decisionOf(out, .@"tool.before", "{\"type\":\"allow\"}") == .block);
}
