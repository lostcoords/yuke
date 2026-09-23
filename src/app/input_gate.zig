//! The `input.before` gate of the headless frontends: a hook call folds the chain, and the owner then runs the typed command.

const std = @import("std");
const proto = @import("proto");
const call = @import("call.zig");
const App = @import("app.zig").App;
const Host = @import("../js/host.zig").Host;
const tools = @import("../js/tools.zig");
const port = @import("../js/port.zig");

const point: proto.hook.Point = .@"input.before";
const Create = proto.misc.CreateSession;
const Send = proto.session.SessionSendInputParams;

/// The answer of the command that `Params` names.
pub fn AnswerOf(comptime Params: type) type {
    return call.Answer(call.specOf(methodOf(Params)).result);
}

fn methodOf(comptime Params: type) proto.enums.MethodName {
    return switch (Params) {
        Create => .@"session.create",
        Send => .@"session.send_input",
        else => @compileError("the gate holds only input commands"),
    };
}

/// Report whether a handler waits on this command: only a content input reaches `input.before`.
pub fn gates(host: *const Host, params: anytype) bool {
    const input: ?proto.input.Input = if (@TypeOf(params) == Create) params.initial_input else params.input;
    return host.hooks.holds(point) and input != null and input.? == .content;
}

/// Submit the hook for a content input that a handler waits on, or return null to run the command now. The call borrows `arena`.
pub fn submit(host: *Host, arena: std.mem.Allocator, params: anytype) ?*tools.Call {
    if (!gates(host, params)) return null;
    const input: proto.input.Input = if (@TypeOf(params) == Create) params.initial_input.? else params.input;
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    // A proposed session has no id yet, so a create names an explicit null and the rest of its parameters.
    const json = if (@TypeOf(params) == Create) blk: {
        var create = params;
        create.initial_input = null;
        break :blk std.json.Stringify.valueAlloc(arena, .{ .session_id = null, .content = input.content.content, .create = create }, options);
    } else std.json.Stringify.valueAlloc(arena, .{ .session_id = params.session_id, .content = input.content.content }, options);
    return host.calls.submitHook(point.wireName(), json catch unreachable);
}

/// Apply the settled chain of `record` to `params`, then run the command unless a handler refused it. A null record runs the command as it is.
pub fn finish(runtime: *App, host: *Host, arena: std.mem.Allocator, params: anytype, record: ?*const tools.Call) !AnswerOf(@TypeOf(params)) {
    var resolved = params;
    if (record) |settled| switch (port.answerOf(arena, point, settled)) {
        .proceed => {},
        .block => return .{ .failure = .{ .code = .bad_request, .message = "an extension stopped the input" } },
        .canceled => unreachable, // Only a waiting submitter reads a cancel; a settled call never does.
        .replace => |value| {
            const replaced = std.json.parseFromValueLeaky(struct { content: []const proto.content.ContentPart }, arena, value, .{ .ignore_unknown_fields = true }) catch
                return .{ .failure = .{ .code = .bad_request, .message = "the input hook answered an unreadable replacement" } };
            const next: proto.input.Input = .{ .content = .{ .content = replaced.content } };
            if (@TypeOf(params) == Create) resolved.initial_input = next else resolved.input = next;
        },
    };
    return call.run(methodOf(@TypeOf(params)), runtime, host, arena, resolved);
}
