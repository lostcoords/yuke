//! Decode a wire request, dispatch it, and write its response frame.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const State = @import("State.zig");
const handlers = @import("handlers.zig");
const connection = @import("connection.zig");
const run_task = @import("run_task.zig");
const RunSlot = @import("session_runtime.zig").RunSlot;

/// Result for one frame: keep reading or close the connection.
pub const Outcome = enum { keep_open, close };

pub const HandleResult = struct {
    outcome: Outcome,
    launch: ?*RunSlot = null,
};

/// Handle one text frame: decode it, dispatch it, and write the response.
/// Use a per-request arena for decoded data and response bytes. Nothing escapes the arena.
pub fn handleRequest(state: *State, conn: *connection.Connection, out: *std.Io.Writer, frame: []const u8) !HandleResult {
    var arena_state: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse the frame as JSON first. Then a typed-decode error can include the request id.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .outcome = try closeProtocol(out) },
    };
    // The daemon needs an id to match a response to the request, so it closes the connection.
    const request_id = requestId(value) orelse return .{ .outcome = try closeProtocol(out) };
    // Report unknown_method for an unknown method. Report bad_request for bad parameters.
    if (requestMethod(value) == null)
        return .{ .outcome = try respond(arena, out, errorResponse(request_id, .unknown_method, "unknown method")) };

    const request = wire.rpc.Request.jsonParseFromValue(arena, value, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .outcome = try respond(arena, out, errorResponse(request_id, .bad_request, "bad request")) },
    };

    // Preserve OutOfMemory. Map every other dispatch error to an internal error response.
    var launch: ?*RunSlot = null;
    errdefer if (launch) |slot| run_task.launchSlot(state, slot) catch |err| {
        std.log.err("cannot release the run launch gate: {t}", .{err});
    };
    const response = dispatch(state, conn, arena, request, &launch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => errorResponse(request_id, .internal, "internal error"),
    };
    return .{ .outcome = try respond(arena, out, response), .launch = launch };
}

fn dispatch(state: *State, conn: *connection.Connection, arena: std.mem.Allocator, request: wire.rpc.Request, launch: *?*RunSlot) !wire.rpc.Response {
    switch (request.method) {
        .initialize => {
            const params = request.params.initialize_params;
            if (params.protocol != wire.meta.protocol_version)
                return errorResponse(request.id, .bad_protocol, "unsupported protocol version");
            const result = try handlers.initialize(state, arena);
            return .{ .ok = .{ .id = request.id, .result = .{ .initialize_result = result } } };
        },
        .@"session.create" => {
            const result = try handlers.sessionCreate(state, arena, request.params.create_session);
            return .{ .ok = .{ .id = request.id, .result = .{ .session_result = result } } };
        },
        .@"session.list" => {
            const result = handlers.sessionList(state, arena, request.params.session_list_params) catch |err| switch (err) {
                error.BadCursor => return errorResponse(request.id, .stale_cursor, "stale cursor"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_list_result = result } } };
        },
        .@"session.config" => {
            const result = handlers.sessionConfig(state, arena, request.params.session_config_params) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                error.UnknownConfigRev => return errorResponse(request.id, .unknown_config_rev, "unknown config revision"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_config_result = result } } };
        },
        .@"session.history" => {
            const result = handlers.sessionHistory(state, arena, request.params.session_history_params) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_history_result = result } } };
        },
        .@"subscription.set" => {
            try state.registry.setSubscriptions(conn, request.params.subscription_set_params.sessions);
            return .{ .ok = .{ .id = request.id, .result = .{ .empty = .{} } } };
        },
        .@"session.send_input" => {
            const result = handlers.sessionSendInputForRpc(state, arena, request.params.session_send_input_params, launch) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                error.SkillUnsupported => return errorResponse(request.id, .unknown_skill, "skills are not supported"),
                error.QueueFull => return errorResponse(request.id, .queue_full, "the input queue is full"),
                error.RuntimeFailed => return errorResponse(request.id, .runtime_failed, "the session runtime failed"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_send_input_result = result } } };
        },
        .@"session.cancel_input" => {
            const result = handlers.sessionCancelInput(state, arena, request.params.session_cancel_input_params) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                error.UnknownInput => return errorResponse(request.id, .unknown_input, "unknown queued input"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_cancel_input_result = result } } };
        },
        .@"session.cancel_run" => {
            const result = handlers.sessionCancelRun(state, arena, request.params.session_cancel_run_params) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                error.RunMismatch => return errorResponse(request.id, .run_mismatch, "the active run does not match"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_cancel_run_result = result } } };
        },
        .@"session.patch",
        .@"session.remove",
        .@"session.fork",
        .@"session.compact",
        .@"session.rewind",
        .@"session.resync",
        .@"permission.decide",
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
        => return errorResponse(request.id, .unknown_method, "not implemented"),
    }
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
const engine_run = @import("../engine/run.zig");

/// Test request handlers with a daemon state and an in-memory database.
const TestState = struct {
    rt: *zio.Runtime,
    state: State,
    conn: *connection.Connection,

    fn init() !TestState {
        const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
        errdefer rt.deinit();
        const listen = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
        // A heap Connection keeps a stable address for its channel across the returned struct's move.
        const conn = try std.testing.allocator.create(connection.Connection);
        errdefer std.testing.allocator.destroy(conn);
        conn.init(std.testing.allocator);
        errdefer conn.deinit();
        const sqlite = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode);
        const db = try database.Database.open(sqlite);
        const state = try State.init(std.testing.allocator, rt.io(), db, .{ .listen = listen }, "/home/test");
        return .{ .rt = rt, .state = state, .conn = conn };
    }

    fn deinit(self: *TestState) void {
        self.conn.deinit();
        std.testing.allocator.destroy(self.conn);
        self.state.deinit();
        self.rt.deinit();
    }
};

fn call(fixture: *TestState, frame: []const u8, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try handleRequest(&fixture.state, fixture.conn, &out, frame);
    return out.buffered();
}

fn createCall(fixture: *TestState, id: []const u8, path: []const u8, buffer: []u8) ![]const u8 {
    var frame: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &frame,
        "{{\"id\":\"{s}\",\"method\":\"session.create\",\"params\":{{\"workspace_path\":\"{s}\"}}}}",
        .{ id, path },
    );
    return call(fixture, request, buffer);
}

fn launchUntilIdle(state: *State, session_id: wire.ids.SessionId) !void {
    var attempts: usize = 0;
    while (attempts < 10_000) : (attempts += 1) {
        const rt = state.sessions.get(session_id) orelse return;
        if (rt.active == null and rt.queue.depth() == 0) return;
        try zio.yield();
    }
    return error.RunDidNotFinish;
}

fn countNamedEvents(db: *database.Database, name: []const u8) !i64 {
    const row = (try db.conn.row("SELECT count(*) FROM events WHERE name = ?1", .{name})) orelse return error.NoRow;
    defer row.deinit();
    return row.int(0);
}

/// Return the payload of one unmasked server text frame. Read the length header, never scan for a brace,
/// because the 2-byte length can hold a '{' byte.
fn responsePayload(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2) return error.InvalidResponse;
    const indicator = bytes[1] & 0x7f; // The server sends a frame without a mask.
    var offset: usize = 2;
    var payload_len: usize = indicator;
    if (indicator == 126) {
        if (bytes.len < 4) return error.InvalidResponse;
        payload_len = std.mem.readInt(u16, bytes[2..4], .big);
        offset = 4;
    } else if (indicator == 127) {
        if (bytes.len < 10) return error.InvalidResponse;
        payload_len = @intCast(std.mem.readInt(u64, bytes[2..10], .big));
        offset = 10;
    }
    if (payload_len > bytes.len - offset) return error.InvalidResponse; // subtract to avoid an overflow
    return bytes[offset .. offset + payload_len];
}

fn responseNextCursor(arena: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try responsePayload(bytes), .{});
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    const result = switch (object.get("result") orelse return error.InvalidResponse) {
        .object => |result| result,
        else => return error.InvalidResponse,
    };
    const cursor = result.get("next_cursor") orelse return null;
    return switch (cursor) {
        .string => |text| text,
        .null => null,
        else => error.InvalidResponse,
    };
}

fn responseItemCount(bytes: []const u8) !usize {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), try responsePayload(bytes), .{});
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    const result = switch (object.get("result") orelse return error.InvalidResponse) {
        .object => |result| result,
        else => return error.InvalidResponse,
    };
    return switch (result.get("items") orelse return error.InvalidResponse) {
        .array => |items| items.items.len,
        else => error.InvalidResponse,
    };
}

fn responseUpdatedAt(bytes: []const u8) ![2]u64 {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), try responsePayload(bytes), .{});
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    const result = switch (object.get("result") orelse return error.InvalidResponse) {
        .object => |result| result,
        else => return error.InvalidResponse,
    };
    const items = switch (result.get("items") orelse return error.InvalidResponse) {
        .array => |items| items.items,
        else => return error.InvalidResponse,
    };
    if (items.len != 2) return error.InvalidResponse;

    var updated_at: [2]u64 = undefined;
    for (items, 0..) |item, i| {
        const item_object = switch (item) {
            .object => |item_object| item_object,
            else => return error.InvalidResponse,
        };
        const session = switch (item_object.get("session") orelse return error.InvalidResponse) {
            .object => |session| session,
            else => return error.InvalidResponse,
        };
        updated_at[i] = switch (session.get("updated_at_ms") orelse return error.InvalidResponse) {
            .integer => |timestamp| @intCast(timestamp),
            else => return error.InvalidResponse,
        };
    }
    return updated_at;
}

test "dispatch initialize returns a result" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"1","method":"initialize","params":{"client":{"name":"test","version":"0"}}}
    ;
    _ = try handleRequest(&fixture.state, fixture.conn, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "server_now_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"1\"") != null);
    // The clock uses the current time, so it exceeds this 2023 timestamp.
    try std.testing.expect(fixture.state.nowMillis() > 1_700_000_000_000);
    // A fresh daemon has no workspaces and a zero session revision.
    try std.testing.expect(std.mem.indexOf(u8, written, "\"workspaces\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"session_revision\":0") != null);
}

test "initialize lists the workspaces the stores hold" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var create_buffer: [4096]u8 = undefined;
    _ = try createCall(&fixture, "1", "/init/proj", &create_buffer);

    var buffer: [4096]u8 = undefined;
    const written = try call(&fixture,
        \\{"id":"2","method":"initialize","params":{"client":{"name":"test","version":"0"}}}
    , &buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"root\":\"/init/proj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"title\":\"proj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"local\"") != null);
}

test "dispatch reports an unknown method with the request id" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"7","method":"not_a_method","params":{}}
    ;
    _ = try handleRequest(&fixture.state, fixture.conn, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "-32601") != null);
}

test "dispatch session.create persists and returns the session" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const frame =
        \\{"id":"2","method":"session.create","params":{"workspace_path":"/home/x/proj","model":"opus"}}
    ;
    _ = try handleRequest(&fixture.state, fixture.conn, &out, frame);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"title\":\"proj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"model\":\"opus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"root\"") != null);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u64, 1), try database.session.count(&fixture.state.db, arena.allocator(), .{}));
}

test "session.create defaults the workspace to home and stacks sessions" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buf1: [4096]u8 = undefined;
    var out1: std.Io.Writer = .fixed(&buf1);
    const empty_params =
        \\{"id":"1","method":"session.create","params":{}}
    ;
    _ = try handleRequest(&fixture.state, fixture.conn, &out1, empty_params);
    // The home default is "/home/test"; its basename is the title.
    try std.testing.expect(std.mem.indexOf(u8, out1.buffered(), "\"title\":\"test\"") != null);

    var buf2: [4096]u8 = undefined;
    var out2: std.Io.Writer = .fixed(&buf2);
    _ = try handleRequest(&fixture.state, fixture.conn, &out2, empty_params);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u64, 2), try database.session.count(&fixture.state.db, arena.allocator(), .{}));
}

test "session.list returns created sessions newest-first" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var create_one: [4096]u8 = undefined;
    var create_two: [4096]u8 = undefined;
    _ = try createCall(&fixture, "1", "/list/one", &create_one);
    _ = try createCall(&fixture, "2", "/list/two", &create_two);

    var list_buffer: [8192]u8 = undefined;
    const written = try call(&fixture,
        \\{"id":"3","method":"session.list","params":{}}
    , &list_buffer);
    try std.testing.expectEqual(@as(usize, 2), try responseItemCount(written));
    const updated_at = try responseUpdatedAt(written);
    try std.testing.expect(updated_at[0] >= updated_at[1]);
    const first_title = std.mem.indexOf(u8, written, "\"title\":\"one\"") orelse return error.MissingTitle;
    const second_title = std.mem.indexOf(u8, written, "\"title\":\"two\"") orelse return error.MissingTitle;
    try std.testing.expect(first_title != second_title);
}

test "session.list pages with a selector-bound cursor" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var create_one: [4096]u8 = undefined;
    var create_two: [4096]u8 = undefined;
    var create_three: [4096]u8 = undefined;
    _ = try createCall(&fixture, "1", "/page/one", &create_one);
    _ = try createCall(&fixture, "2", "/page/two", &create_two);
    _ = try createCall(&fixture, "3", "/page/three", &create_three);

    var first_buffer: [8192]u8 = undefined;
    const first = try call(&fixture,
        \\{"id":"4","method":"session.list","params":{"limit":2}}
    , &first_buffer);
    try std.testing.expectEqual(@as(usize, 2), try responseItemCount(first));

    var cursor_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cursor_arena.deinit();
    const cursor = (try responseNextCursor(cursor_arena.allocator(), first)) orelse return error.MissingCursor;
    var second_frame: [8192]u8 = undefined;
    const second_request = try std.fmt.bufPrint(
        &second_frame,
        "{{\"id\":\"5\",\"method\":\"session.list\",\"params\":{{\"limit\":2,\"cursor\":\"{s}\"}}}}",
        .{cursor},
    );
    var second_buffer: [8192]u8 = undefined;
    const second = try call(&fixture, second_request, &second_buffer);
    try std.testing.expectEqual(@as(usize, 1), try responseItemCount(second));
    try std.testing.expect((try responseNextCursor(cursor_arena.allocator(), second)) == null);

    // Each session appears on exactly one page. The cursor advances with no duplicate or skipped row.
    inline for (.{ "one", "two", "three" }) |name| {
        const on_first = std.mem.indexOf(u8, first, "\"title\":\"" ++ name ++ "\"") != null;
        const on_second = std.mem.indexOf(u8, second, "\"title\":\"" ++ name ++ "\"") != null;
        try std.testing.expect(on_first != on_second);
    }
}

test "session.list workspace scope filters sessions" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var create_one: [4096]u8 = undefined;
    var create_two: [4096]u8 = undefined;
    _ = try createCall(&fixture, "1", "/scope/one", &create_one);
    _ = try createCall(&fixture, "2", "/scope/two", &create_two);

    var id_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer id_arena.deinit();
    const workspace = try database.workspace.resolve(
        &fixture.state.db,
        id_arena.allocator(),
        [_]u8{9} ** 16,
        "/scope/one",
        "one",
        "/scope/one",
    );
    var scope_buffer: std.Io.Writer.Allocating = .init(id_arena.allocator());
    const scope = wire.scope.SessionScope{ .workspace = .{ .workspace_id = .bytes(workspace.id) } };
    try std.json.Stringify.value(scope, .{}, &scope_buffer.writer);
    var request: [8192]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &request,
        "{{\"id\":\"3\",\"method\":\"session.list\",\"params\":{{\"scope\":{s}}}}}",
        .{scope_buffer.written()},
    );
    var list_buffer: [8192]u8 = undefined;
    const written = try call(&fixture, frame, &list_buffer);
    try std.testing.expectEqual(@as(usize, 1), try responseItemCount(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "\"title\":\"one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"title\":\"two\"") == null);
}

test "session.list rejects a cursor from a different selector" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var create_buffer: [4096]u8 = undefined;
    _ = try createCall(&fixture, "1", "/stale", &create_buffer);
    var second_create_buffer: [4096]u8 = undefined;
    _ = try createCall(&fixture, "2", "/stale-two", &second_create_buffer);
    var first_buffer: [8192]u8 = undefined;
    const first = try call(&fixture,
        \\{"id":"2","method":"session.list","params":{"limit":1}}
    , &first_buffer);
    var cursor_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer cursor_arena.deinit();
    const cursor = (try responseNextCursor(cursor_arena.allocator(), first)) orelse return error.MissingCursor;

    var request: [8192]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &request,
        "{{\"id\":\"3\",\"method\":\"session.list\",\"params\":{{\"population\":{{\"type\":\"all\"}},\"cursor\":\"{s}\"}}}}",
        .{cursor},
    );
    var stale_buffer: [8192]u8 = undefined;
    const stale = try call(&fixture, frame, &stale_buffer);
    try std.testing.expect(std.mem.indexOf(u8, stale, "-31002") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale, "\"id\":\"3\"") != null);
}

test "session.create records the initial config as revision 0" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/p", .model = "opus", .reasoning = "high" });
    // The initial config is readable by its revision, not only as the current config.
    const cfg = try handlers.sessionConfig(&fixture.state, a, .{ .session_id = created.session.id, .config_rev = 0 });
    try std.testing.expectEqual(@as(u64, 0), cfg.config.config_rev);
    try std.testing.expectEqualStrings("opus", cfg.config.model);
}

test "session.history returns committed messages oldest-first with their configs" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/p", .model = "opus", .reasoning = "high" });
    const sid = created.session.id;

    const user: wire.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 150 } } };
    const assistant: wire.message.Message = .{
        .assistant = .{
            .id = 2,
            .run_id = 1,
            .config_rev = 0, // references the initial config recordInitial stored
            .agent = "claude",
            .content = &.{},
            .time = .{ .created_at_ms = 160 },
        },
    };
    try fixture.state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    _ = try database.message.appendCommittedMessage(&fixture.state.db, a, sid.raw, [_]u8{1} ** 16, 150, user);
    _ = try database.message.appendCommittedMessage(&fixture.state.db, a, sid.raw, [_]u8{2} ** 16, 160, assistant);
    try fixture.state.db.conn.execNoArgs("COMMIT");

    const hist = try handlers.sessionHistory(&fixture.state, a, .{ .session_id = sid, .before_message_id = 0, .limit = 10 });
    try std.testing.expectEqual(@as(usize, 2), hist.messages.len);
    try std.testing.expectEqual(@as(u64, 1), hist.messages[0].user.id); // oldest first
    try std.testing.expectEqual(@as(u64, 2), hist.messages[1].assistant.id);
    try std.testing.expect(!hist.has_more);
    // The assistant turn references config_rev 0, so gatherConfigs resolves exactly that revision.
    try std.testing.expectEqual(@as(usize, 1), hist.configs.len);
    try std.testing.expectEqual(@as(u64, 0), hist.configs[0].config_rev);
}

test "session reads reject an unknown session and an unknown revision" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const missing: wire.ids.SessionId = .bytes([_]u8{9} ** 16);
    try std.testing.expectError(error.UnknownSession, handlers.sessionConfig(&fixture.state, a, .{ .session_id = missing }));
    try std.testing.expectError(error.UnknownSession, handlers.sessionHistory(&fixture.state, a, .{ .session_id = missing, .before_message_id = 0 }));

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/p" });
    try std.testing.expectError(error.UnknownConfigRev, handlers.sessionConfig(&fixture.state, a, .{ .session_id = created.session.id, .config_rev = 99 }));
}

test "session.config dispatch maps an unknown session to its error code" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var buffer: [4096]u8 = undefined;
    // A printable 16-byte id decodes fine but matches no session.
    const written = try call(&fixture,
        \\{"id":"1","method":"session.config","params":{"session_id":"0123456789abcdef0123456789abcdef"}}
    , &buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "-31000") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"1\"") != null);
}

test "a completed run drains every queued input into one next run" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/drain", .model = "mock" });
    const sid = created.session.id;
    const one = [_]wire.content.ContentPart{.{ .text = .{ .text = "one" } }};
    const two = [_]wire.content.ContentPart{.{ .text = .{ .text = "two" } }};
    const three = [_]wire.content.ContentPart{.{ .text = .{ .text = "three" } }};
    const first = try handlers.sessionSendInput(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &one } } });
    try std.testing.expect(first == .started);
    const second = try handlers.sessionSendInput(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &two } } });
    const third = try handlers.sessionSendInput(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &three } } });
    try std.testing.expect(second == .queued);
    try std.testing.expect(third == .queued);
    try std.testing.expectEqual(@as(usize, 2), fixture.state.sessions.get(sid).?.queue.depth());

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 5), history.len);
    try std.testing.expectEqualStrings("one", history[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("two", history[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("three", history[3].user.content[0].text.text);
    try std.testing.expect(history[1] == .assistant);
    try std.testing.expect(history[4] == .assistant);
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "run.started"));
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "run.done"));
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "input.queued"));
    try std.testing.expectEqual(@as(i64, 0), try countNamedEvents(&fixture.state.db, "input.canceled"));

    // The session summary counts every message and folds the assistant usage of both runs.
    const snap = (try database.session.snapshot(&fixture.state.db, a, sid.raw)).?;
    try std.testing.expect(snap.open_run_id == null);
    try std.testing.expectEqual(@as(u64, 5), snap.message_count);
    try std.testing.expectEqual(@as(u64, 0), snap.usage_input_total);
    try std.testing.expectEqual(@as(u64, 16), snap.usage_output_total);
    // The committed assistant record carries the session's configured model.
    try std.testing.expectEqualStrings("mock", history[1].assistant.provenance.?.model);
}

test "a durable queue starts before a new idle input" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/resume", .model = "mock" });
    const sid = created.session.id;
    const old_content = [_]wire.content.ContentPart{.{ .text = .{ .text = "old" } }};
    const new_content = [_]wire.content.ContentPart{.{ .text = .{ .text = "new" } }};
    try fixture.state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    const old = try database.input.enqueue(&fixture.state.db, a, sid.raw, fixture.state.newId(), 100, &old_content, 100);
    try fixture.state.db.conn.execNoArgs("COMMIT");
    const runtime = try fixture.state.sessions.getOrCreate(sid);
    try std.testing.expectEqual(.changed, runtime.queue.onQueued(.{ .session_id = sid, .input = old.input }));

    const accepted = try handlers.sessionSendInput(&fixture.state, a, .{
        .session_id = sid,
        .input = .{ .content = .{ .content = &new_content } },
    });
    try std.testing.expect(accepted == .queued);
    try std.testing.expectEqual(old.input.input_id, runtime.active.?.handle.input_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.queue.depth());

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 4), history.len);
    try std.testing.expectEqualStrings("old", history[0].user.content[0].text.text);
    try std.testing.expect(history[1] == .assistant);
    try std.testing.expectEqualStrings("new", history[2].user.content[0].text.text);
    try std.testing.expect(history[3] == .assistant);
}

test "a faulted runtime retains the old open-run fence" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/fault", .model = "mock" });
    const sid = created.session.id;
    const content = [_]wire.content.ContentPart{.{ .text = .{ .text = "first" } }};
    const old = try engine_run.beginTurn(&fixture.state.db, fixture.state.io, a, sid.raw, &content, 0);
    const rt = try fixture.state.sessions.getOrCreate(sid);
    rt.faulted = true;
    fixture.state.sessions.evictIfIdle(sid);
    try std.testing.expect(fixture.state.sessions.get(sid) == rt);

    try std.testing.expectError(error.RuntimeFailed, handlers.sessionSendInput(&fixture.state, a, .{
        .session_id = sid,
        .input = .{ .content = .{ .content = &content } },
    }));
    try std.testing.expectEqual(@as(?u64, old.run_id), (try database.session.snapshot(&fixture.state.db, a, sid.raw)).?.open_run_id);
    try std.testing.expectEqual(@as(i64, 1), try countNamedEvents(&fixture.state.db, "run.started"));
}

test "cancel input and cancel run preserve exact durable outcomes" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/cancel", .model = "mock" });
    const sid = created.session.id;
    const content = [_]wire.content.ContentPart{.{ .text = .{ .text = "input" } }};
    const started = (try handlers.sessionSendInput(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &content } } })).started;
    const queued_one = (try handlers.sessionSendInput(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &content } } })).queued;
    const queued_two = (try handlers.sessionSendInput(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &content } } })).queued;

    try std.testing.expectError(error.RunMismatch, handlers.sessionCancelRun(&fixture.state, a, .{ .session_id = sid, .run_id = started.run_id + 1 }));
    _ = try handlers.sessionCancelInput(&fixture.state, a, .{ .session_id = sid, .input_id = queued_one.input_id });
    try std.testing.expectError(error.UnknownInput, handlers.sessionCancelInput(&fixture.state, a, .{ .session_id = sid, .input_id = queued_one.input_id }));
    const canceled = try handlers.sessionCancelRun(&fixture.state, a, .{
        .session_id = sid,
        .run_id = started.run_id,
        .clear_queue = true,
    });
    try std.testing.expectEqual(@as(?u64, started.run_id), canceled.canceled_run);
    try std.testing.expectEqualSlices(u64, &.{queued_two.input_id}, canceled.cleared_inputs);
    const repeated = try handlers.sessionCancelRun(&fixture.state, a, .{ .session_id = sid, .run_id = started.run_id });
    try std.testing.expectEqual(@as(?u64, started.run_id), repeated.canceled_run);
    try std.testing.expectEqual(@as(usize, 0), repeated.cleared_inputs.len);

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "input.canceled"));
    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .canceled);
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqual(wire.enums.StopReason.canceled, history[1].assistant.finish.?);
}
