//! Decode a wire request, dispatch it, and write its response frame.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const State = @import("State.zig");

/// Result for one frame: keep reading or close the connection.
pub const Outcome = enum { keep_open, close };

/// Handle one text frame: decode it, dispatch it, and write the response.
/// Use a per-request arena for decoded data and response bytes. Nothing escapes the arena.
pub fn handleRequest(state: *State, out: *std.Io.Writer, frame: []const u8) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse the frame as JSON first. Then a typed-decode error can include the request id.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return closeProtocol(out),
    };
    // The daemon needs an id to match a response to the request, so it closes the connection.
    const request_id = requestId(value) orelse return closeProtocol(out);
    // Report unknown_method for an unknown method. Report bad_request for bad parameters.
    if (requestMethod(value) == null)
        return respond(arena, out, errorResponse(request_id, .unknown_method, "unknown method"));

    const request = wire.rpc.Request.jsonParseFromValue(arena, value, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return respond(arena, out, errorResponse(request_id, .bad_request, "bad request")),
    };

    return respond(arena, out, dispatch(state, request));
}

fn dispatch(state: *State, request: wire.rpc.Request) wire.rpc.Response {
    switch (request.method) {
        .initialize => {
            const params = request.params.initialize_params;
            if (params.protocol != wire.meta.protocol_version)
                return errorResponse(request.id, .bad_protocol, "unsupported protocol version");
            return .{ .ok = .{ .id = request.id, .result = .{ .initialize_result = initializeResult(state) } } };
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

/// Report the daemon handshake. Use the real clock; keep store revisions at 0 until stores exist.
fn initializeResult(state: *const State) wire.misc.InitializeResult {
    return .{
        .protocol = wire.meta.protocol_version,
        .daemon = .{ .version = "0.0.1", .server_now_ms = state.nowMillis() },
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

/// Read a string request id. Return null for a missing or invalid id.
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

/// Read the method as a known name. Return null for a missing, non-string, or unknown name.
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

const zio = @import("zio");
const zqlite = @import("zqlite");
const database = @import("../database/database.zig");

/// Test request handlers with a daemon state and an in-memory database.
const TestState = struct {
    rt: *zio.Runtime,
    state: State,

    fn init() !TestState {
        const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
        errdefer rt.deinit();
        const listen = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
        const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
        // Database.open is the last fallible step. It closes conn on failure.
        const db = try database.Database.open(conn);
        return .{ .rt = rt, .state = .{
            .gpa = std.testing.allocator,
            .io = rt.io(),
            .db = db,
            .config = .{ .listen = listen },
        } };
    }

    fn deinit(self: *TestState) void {
        self.state.db.deinit();
        self.rt.deinit();
    }
};

test "dispatch initialize returns a result" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"1","method":"initialize","params":{"client":{"name":"test","version":"0"}}}
    ;
    _ = try handleRequest(&fixture.state, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "server_now_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"1\"") != null);
    // The clock uses the current time, so it exceeds this 2023 timestamp.
    try std.testing.expect(fixture.state.nowMillis() > 1_700_000_000_000);
}

test "dispatch reports an unknown method with the request id" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"7","method":"not_a_method","params":{}}
    ;
    _ = try handleRequest(&fixture.state, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "-32601") != null);
}
