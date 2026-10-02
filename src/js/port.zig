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
    return .{ .ctx = host, .decls = declsFor, .run = runFor, .spill = spillFor };
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
    const call = host.calls.submit(name, arguments, context);
    const tool = &call.kind.tool;
    defer finishCall(host, call);
    host.wake.set(host.io);
    // Each chunk swaps with this empty list, so the owner appends into capacity a chunk already grew.
    var spare: std.ArrayList(u8) = .empty;
    defer spare.deinit(host.gpa);
    // Publish each output chunk while the tool runs, and the last one before the result.
    while (true) {
        call.wake.wait(host.io) catch return fault(out, "cancellation stopped the tool call");
        call.wake.reset();
        if (tool.output.items.len != 0) {
            // Swap the chunk out before the sink publishes it.
            std.mem.swap(std.ArrayList(u8), &tool.output, &spare);
            defer spare.clearRetainingCapacity();
            context.output.write(context.output.ctx, spare.items);
        }
        if (call.state == .settled) break;
    }
    return outcomeOf(out, toolSet(host), call.state.settled);
}

/// Write the whole text of a cut result to a new file in the host log directory. Return its path, allocated with `out`, or null when the write fails.
fn spillFor(ctx: *anyopaque, out: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const path = host.logs.next(host.gpa, host.io, host.execution.env, "tool") catch return null;
    defer host.gpa.free(path);
    std.Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = text }) catch return null;
    return out.dupe(u8, path) catch null;
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
    host.wake.set(host.io);
    call.wake.wait(host.io) catch return .canceled;
    if (host.phase != .open) return .canceled;
    return answerOf(out, point, call);
}

/// Read the answer of one settled hook call into `out`. A fault or an unreadable answer blocks, and a closed host cancels.
pub fn answerOf(out: std.mem.Allocator, point: proto.hook.Point, call: *const tools.Call) hookset.Decision {
    const text = switch (call.state.settled) {
        .ok => |reply| reply.text,
        .failed => |text| {
            std.log.warn("hook {s} faulted: {s}", .{ point.wireName(), text });
            return .{ .block = "the hook dispatch failed" };
        },
        .closed => return .canceled,
    };
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

/// Read the answer of one settled tool call into `out`, because the owner frees the answer on its next sweep. A `ToolOutcome` with an unknown key is an error.
/// A text over the cap is cut here, so the whole text never gets a second copy.
pub fn outcomeOf(out: std.mem.Allocator, set: toolset.ToolSet, answer: tools.Call.Answer) toolset.Outcome {
    const reply = switch (answer) {
        .ok => |value| value,
        .failed => |text| return fault(out, text),
        .closed => return fault(out, "the tool call did not finish"),
    };
    if (!reply.outcome) {
        const capped = toolset.cut(set, out, reply.text) catch @panic("out of memory");
        return .{ .output = capped orelse out.dupe(u8, reply.text) catch @panic("out of memory") };
    }
    return std.json.parseFromSliceLeaky(toolset.Outcome, out, reply.text, .{ .allocate = .alloc_always }) catch
        fault(out, "the tool answered an object that is not a ToolOutcome");
}

fn fault(out: std.mem.Allocator, message: []const u8) toolset.Outcome {
    return .{ .output = out.dupe(u8, message) catch message, .is_error = true };
}

test "a tool outcome owns its data after the call answer leaves, and an unknown key fails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json = try std.testing.allocator.dupe(u8, "{\"output\":\"done\",\"media\":[{\"hash\":\"" ++ "ab" ** 32 ++ "\",\"mime\":\"image/png\",\"bytes\":3}],\"tools_added\":[{\"name\":\"mcp_read\",\"description\":\"Read.\",\"input_schema\":\"{}\"}]}");
    const outcome = outcomeOf(arena.allocator(), .{}, .{ .ok = .{ .text = json, .outcome = true } });
    @memset(json, 'x');
    std.testing.allocator.free(json);
    try std.testing.expect(!outcome.is_error);
    try std.testing.expectEqualStrings("done", outcome.output);
    try std.testing.expectEqualStrings("image/png", outcome.media[0].mime);
    try std.testing.expectEqual(@as(u64, 3), outcome.media[0].bytes);
    try std.testing.expectEqualStrings("mcp_read", outcome.tools_added[0].name);
    const unknown = try arena.allocator().dupe(u8, "{\"output\":\"x\",\"text\":\"y\"}");
    try std.testing.expect(outcomeOf(arena.allocator(), .{}, .{ .ok = .{ .text = unknown, .outcome = true } }).is_error);
    // Plain text is model text, even when it reads as JSON.
    const plain = try arena.allocator().dupe(u8, "{\"text\":\"y\"}");
    try std.testing.expectEqualStrings("{\"text\":\"y\"}", outcomeOf(arena.allocator(), .{}, .{ .ok = .{ .text = plain } }).output);
}

test "a spill writes the whole text to a new file in the host log directory" {
    const support = @import("tests/support.zig");
    const host = support.createHost();
    defer support.destroyHost(host);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const set = toolSet(host);
    const first = set.spill(set.ctx, arena.allocator(), "whole text").?;
    const second = set.spill(set.ctx, arena.allocator(), "more").?;
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, host.logs.dir.?));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("whole text", try std.Io.Dir.cwd().readFile(host.io, first, &buf));
    // A plain answer over the cap is cut at the port, and the file holds the whole answer.
    const big = try std.testing.allocator.alloc(u8, 2 * proto.meta.limits.max_tool_result_bytes);
    defer std.testing.allocator.free(big);
    @memset(big, 'z');
    const decoded = outcomeOf(arena.allocator(), set, .{ .ok = .{ .text = big } });
    try std.testing.expect(decoded.output.len < big.len);
    const marker = "Full output: ";
    const at = std.mem.indexOf(u8, decoded.output, marker).? + marker.len;
    const path = decoded.output[at..][0 .. std.mem.indexOfScalar(u8, decoded.output[at..], ' ').? - 1];
    const saved = try std.Io.Dir.cwd().readFileAlloc(host.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings(big, saved);
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
