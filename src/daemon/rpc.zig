//! Decode a wire request, dispatch it to a handler, and write the response frame.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;

/// The outcome of one frame: keep reading, or the connection was closed.
pub const Outcome = enum { keep_open, close };

/// Handle one text frame: decode, dispatch, and write the response. A per-request arena
/// backs the decode and the response bytes; nothing escapes it.
pub fn handleRequest(gpa: std.mem.Allocator, out: *std.Io.Writer, frame: []const u8) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse the frame to a JSON value first, so a typed-decode error can still name the id.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return closeProtocol(out),
    };
    // Without an id the daemon cannot correlate a response, so it closes.
    const request_id = requestId(value) orelse return closeProtocol(out);
    // An unknown method is distinct from a bad parameter of a known method.
    if (requestMethod(value) == null)
        return respond(arena, out, errorResponse(request_id, .unknown_method, "unknown method"));

    const request = wire.rpc.Request.jsonParseFromValue(arena, value, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return respond(arena, out, errorResponse(request_id, .bad_request, "bad request")),
    };

    return respond(arena, out, dispatch(request));
}

fn dispatch(request: wire.rpc.Request) wire.rpc.Response {
    switch (request.method) {
        .initialize => {
            const params = request.params.initialize_params;
            if (params.protocol != wire.meta.protocol_version)
                return errorResponse(request.id, .bad_protocol, "unsupported protocol version");
            return .{ .ok = .{ .id = request.id, .result = .{ .initialize_result = initializeResult() } } };
        },
        .@"session.list",
        .@"session.create",
        .@"session.patch",
        .@"session.remove",
        .@"session.fork",
        .@"session.compact",
        .@"session.rewind",
        .@"session.send_input",
        .@"session.cancel_input",
        .@"session.cancel_run",
        .@"session.resync",
        .@"session.history",
        .@"permission.decide",
        .@"session.config",
        .@"subscription.set",
        .@"catalog.list",
        .@"catalog.refresh",
        .@"auth.list",
        .@"auth.set_api_key",
        .@"auth.login",
        .@"auth.cancel_login",
        .@"auth.logout",
        .@"workspace.describe",
        .@"workspace.browse",
        .@"workspace.remove",
        .@"workspace.skills",
        .@"permission.rules",
        .@"permission.forget",
        .@"cron.create",
        .@"cron.patch",
        .@"cron.remove",
        .@"cron.list",
        .@"cron.run_now",
        => return errorResponse(request.id, .unknown_method, "not implemented"),
    }
}

/// Report the daemon handshake. Slice 4 returns a stub; the stores and the clock fill it later.
fn initializeResult() wire.misc.InitializeResult {
    return .{
        .protocol = wire.meta.protocol_version,
        .daemon = .{ .version = "0.0.1", .server_now_ms = 0 },
        .workspaces = &.{},
        .profiles = &.{},
        .agents = &.{},
        .session_revision = 0,
        .cron_revision = 0,
        .catalog_rev = [_]u8{'0'} ** 64,
        .catalog_health = .{ .skipped = &.{} },
        .capabilities = &.{},
    };
}

fn errorResponse(id: wire.ids.RequestId, code: wire.enums.ErrorCode, message: []const u8) wire.rpc.Response {
    return .{ .err = .{ .id = id, .@"error" = .{ .code = code, .message = message } } };
}

fn respond(arena: std.mem.Allocator, out: *std.Io.Writer, response: wire.rpc.Response) !Outcome {
    const bytes = try std.json.Stringify.valueAlloc(arena, response, .{ .emit_null_optional_fields = false });
    try wss.writeMessage(out, .text, bytes);
    try out.flush();
    return .keep_open;
}

fn closeProtocol(out: *std.Io.Writer) !Outcome {
    try wss.writeClose(out, .protocol_error);
    try out.flush();
    return .close;
}

/// Read a string request id, or return null when the id is absent or invalid.
fn requestId(value: std.json.Value) ?wire.ids.RequestId {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return switch (object.get("id") orelse return null) {
        .string => |id| id,
        else => null,
    };
}

/// Read the method as a known name, or null when it is absent, non-string, or unknown.
fn requestMethod(value: std.json.Value) ?wire.enums.MethodName {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const name = switch (object.get("method") orelse return null) {
        .string => |name| name,
        else => return null,
    };
    return std.meta.stringToEnum(wire.enums.MethodName, name);
}

test "dispatch initialize returns a result" {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"1","method":"initialize","params":{"client":{"name":"test","version":"0"}}}
    ;
    _ = try handleRequest(std.testing.allocator, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "server_now_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"1\"") != null);
}

test "dispatch reports an unknown method with the request id" {
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"7","method":"not_a_method","params":{}}
    ;
    _ = try handleRequest(std.testing.allocator, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "-32601") != null); // unknown_method
}
