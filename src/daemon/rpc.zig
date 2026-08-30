//! Decode a wire request, dispatch it, and write its response frame.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const State = @import("State.zig");
const handlers = @import("handlers.zig");
const cloud_catalog = @import("../cloud/catalog.zig");
const catalog_store = @import("../database/catalog.zig");
const connection = @import("connection.zig");
const run_task = @import("run_task.zig");

/// Store the result for one frame: continue or close the connection.
pub const Outcome = enum { keep_open, close };

pub const HandleResult = struct {
    outcome: Outcome,
    launch: ?run_task.Launch = null,
};

/// Handle one text frame: decode it, dispatch it, and write the response.
/// Use a per-request arena for decoded data and response bytes. Nothing escapes the arena.
pub fn handleRequest(state: *State, conn: *connection.Connection, out: *std.Io.Writer, frame: []const u8) !HandleResult {
    var arena_state: std.heap.ArenaAllocator = .init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse the frame as JSON first. This lets a typed-decode error include the request id.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .outcome = try closeProtocol(out) },
    };
    // The daemon needs an id to match each response. Close the connection when the frame has none.
    const request_id = requestId(value) orelse return .{ .outcome = try closeProtocol(out) };
    // Report unknown_method for an unknown method. Report bad_request for bad parameters.
    if (requestMethod(value) == null)
        return .{ .outcome = try respond(arena, out, errorResponse(request_id, .unknown_method, "unknown method")) };

    // The wire request parser owns the unknown-field policy. It ignores unknown fields for forward
    // compatibility, so use the default call options.
    const request = wire.rpc.Request.jsonParseFromValue(arena, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .outcome = try respond(arena, out, errorResponse(request_id, .bad_request, "bad request")) },
    };

    // Preserve OutOfMemory. Map every other dispatch error to an internal error response.
    var launch: ?run_task.Launch = null;
    errdefer run_task.Launch.release(&launch, state);
    const response = dispatch(state, conn, arena, request, &launch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => errorResponse(request_id, .internal, "internal error"),
    };
    return .{ .outcome = try respond(arena, out, response), .launch = launch };
}

fn dispatch(state: *State, conn: *connection.Connection, arena: std.mem.Allocator, request: wire.rpc.Request, launch: *?run_task.Launch) !wire.rpc.Response {
    switch (request.method) {
        .initialize => {
            const params = request.params.initialize_params;
            if (params.protocol != wire.meta.protocol_version)
                return errorResponse(request.id, .bad_protocol, "unsupported protocol version");
            const result = try handlers.initialize(state, arena);
            return .{ .ok = .{ .id = request.id, .result = .{ .initialize_result = result } } };
        },
        .@"session.create" => {
            const result = handlers.sessionCreate(state, arena, request.params.create_session) catch |err| switch (err) {
                error.RootNotAbsolute => return errorResponse(request.id, .bad_request, "the workspace path must be absolute"),
                else => return err,
            };
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
            state.registry.setSubscriptions(conn, request.params.subscription_set_params.sessions) catch |err| switch (err) {
                error.TooManySubscriptions => return errorResponse(request.id, .bad_request, "too many subscriptions"),
                else => return err,
            };
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
        .@"catalog.list" => {
            const result = try handlers.catalogList(state, arena, request.params.catalog_list_params);
            return .{ .ok = .{ .id = request.id, .result = .{ .catalog_list_result = result } } };
        },
        .@"catalog.refresh" => {
            const result: wire.catalog.CatalogRefreshResult = .{ .catalog_rev = try state.refreshCloud() };
            return .{ .ok = .{ .id = request.id, .result = .{ .catalog_refresh_result = result } } };
        },
        .@"session.resync" => {
            const result = handlers.sessionResync(state, arena, request.params.session_resync_params) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                error.BadRequest => return errorResponse(request.id, .bad_request, "the resync limit is out of range"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .session_resync_result = result } } };
        },
        .@"session.remove" => {
            const result = handlers.sessionRemove(state, arena, request.params.session_remove_params) catch |err| switch (err) {
                error.UnknownSession => return errorResponse(request.id, .unknown_session, "unknown session"),
                error.SessionBusy => return errorResponse(request.id, .session_busy, "the session has an active run"),
                error.SessionHasChildren => return errorResponse(request.id, .session_has_children, "the session has children"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .empty = result } } };
        },
        .@"session.patch",
        .@"session.fork",
        .@"session.compact",
        .@"session.rewind",
        .@"permission.decide",
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

/// Read a string request id. Return null when the id is absent or invalid.
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

/// Read the method as a known name. Return null when the field is absent, not a string, or unknown.
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
const transport = @import("../provider/transport.zig");
const provider = @import("../provider/provider.zig");
const domain_session = @import("domain").session;
const tools = @import("../tools/tool.zig");
const test_host = @import("../tools/test_host.zig");

/// Test request handlers with a daemon state and an in-memory database.
/// The fixture environment is empty. The map has no allocation to free.
var fixture_env: std.process.Environ.Map = .init(std.testing.allocator);

/// Every fixture starts with this canned transport. A test can replace the state transport.
var fixture_transport = provider.transport.CannedTransport{ .bytes = provider.transport.canned_reply };

/// A test uses this provider to resolve `mock/fast` through the production catalog.
const fixture_providers =
    \\{"version":1,"providers":[{"id":"mock","base_url":"https://mock.invalid/v1","protocol":"anthropic_messages",
    \\ "auth":{"api_key":{"header":"x_api_key","source":{"literal":"sk-mock"}}},
    \\ "models":[{"id":"fast","upstream_id":"mock-fast-1","limits":{"context_window":200000,"max_output_tokens":8192}}]}]}
;

/// Decode the frames that one connection receives. A conformance test folds them like a client.
/// The test reads the same frames as a client.
const BroadcastLog = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(wire.rpc.BroadcastData) = .empty,

    fn init() BroadcastLog {
        return .{ .arena = .init(std.testing.allocator) };
    }

    fn deinit(self: *BroadcastLog) void {
        self.arena.deinit();
    }

    /// Return the payload of one unmasked server text frame. The daemon writes only this shape.
    fn payload(frame: []const u8) []const u8 {
        std.debug.assert(frame.len >= 2);
        std.debug.assert(frame[0] == 0x81); // one final text frame
        std.debug.assert(frame[1] & 0x80 == 0); // a server frame carries no mask
        const length = frame[1] & 0x7F;
        const offset: usize = if (length < 126) 2 else if (length == 126) 4 else 10;
        std.debug.assert(frame.len > offset);
        return frame[offset..];
    }

    /// Drain the outbox. Copy each notification, because the caller frees the frame bytes.
    fn drain(self: *BroadcastLog, conn: *connection.Connection) !void {
        const a = self.arena.allocator();
        while (try conn.tryReceive()) |item| {
            defer std.testing.allocator.free(item.bytes);
            const note = try std.json.parseFromSliceLeaky(wire.rpc.Notification, a, payload(item.bytes), .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            try self.events.append(a, note.params);
        }
    }
};

const TestState = struct {
    rt: *zio.Runtime,
    state: State,
    conn: *connection.Connection,
    arena: std.heap.ArenaAllocator,

    /// Build a fixture with no provider layer. A catalog test starts here.
    /// A null `cloud_base_url` keeps the built-in endpoint.
    fn initBare(cloud_base_url: ?[]const u8) !TestState {
        const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
        errdefer rt.deinit();
        const listen = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        // A heap Connection keeps a stable queue address when the returned struct moves.
        const conn = try std.testing.allocator.create(connection.Connection);
        errdefer std.testing.allocator.destroy(conn);
        conn.init(std.testing.allocator, rt.io());
        errdefer conn.deinit();
        const db = try database.Database.openTest();
        var options: State.InitOptions = .{
            .gpa = std.testing.allocator,
            .io = rt.io(),
            .db = db,
            .config = .{ .listen = listen },
            .home = "/home/test",
            .env = &fixture_env,
            .route_transport = fixture_transport.transport(),
        };
        if (cloud_base_url) |url| options.cloud_base_url = url;
        const state = try State.init(options);
        return .{ .rt = rt, .state = state, .conn = conn, .arena = .init(std.testing.allocator) };
    }

    /// Build a fixture that runs turns. The catalog resolves `mock/fast` through the production path.
    fn init() !TestState {
        var fixture = try initBare(null);
        errdefer fixture.deinit();
        // State.deinit frees the provider layer.
        fixture.state.providers = try provider.config.loadBytes(std.testing.allocator, fixture_providers);
        _ = try fixture.state.rebuildCatalog();
        return fixture;
    }

    /// Register the fixture connection. It then receives every registry-wide broadcast.
    fn register(self: *TestState) !void {
        try self.state.registry.register(self.conn);
    }

    /// Subscribe the registered connection to `sid`, so it also receives that session's broadcasts.
    fn subscribe(self: *TestState, sid: wire.ids.SessionId) !void {
        try self.state.registry.setSubscriptions(self.conn, &.{sid});
    }

    /// One arena per test. It frees every handler result at `deinit`.
    fn allocator(self: *TestState) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *TestState) void {
        self.arena.deinit();
        self.state.registry.unregister(self.conn); // Unregister first, so no publish targets a dead outbox.
        self.conn.deinit();
        std.testing.allocator.destroy(self.conn);
        self.state.deinit();
        self.rt.deinit();
    }
};

/// Create a session and return its id.
fn createSession(fixture: *TestState, a: std.mem.Allocator, params: wire.misc.CreateSession) !wire.ids.SessionId {
    const created = try handlers.sessionCreate(&fixture.state, a, params);
    return created.session.id;
}

/// Send one text input through `sendInputDirect`.
fn sendText(fixture: *TestState, a: std.mem.Allocator, sid: wire.ids.SessionId, text: []const u8) !wire.session.SessionSendInputResult {
    const content = [_]wire.content.ContentPart{.{ .text = .{ .text = text } }};
    return sendInputDirect(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &content } } });
}

fn call(fixture: *TestState, frame: []const u8, buffer: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    _ = try handleRequest(&fixture.state, fixture.conn, &out, frame);
    return out.buffered();
}

/// Send input and launch any prepared run directly. Tests use this in place of the RPC response gate.
fn sendInputDirect(state: *State, arena: std.mem.Allocator, params: wire.session.SessionSendInputParams) !wire.session.SessionSendInputResult {
    var launch: ?run_task.Launch = null;
    errdefer run_task.Launch.release(&launch, state);
    const result = try handlers.sessionSendInputForRpc(state, arena, params, &launch);
    if (launch) |l| {
        launch = null;
        try run_task.launchSlot(state, l.slot);
    }
    return result;
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
        if (rt.active == null and rt.session.queue.depth() == 0) return;
        try zio.yield();
    }
    return error.RunDidNotFinish;
}

fn countNamedEvents(db: *database.Database, name: []const u8) !i64 {
    const row = (try db.conn.row("SELECT count(*) FROM events WHERE name = ?1", .{name})) orelse return error.NoRow;
    defer row.deinit();
    return row.int(0);
}

/// Return the payload of one unmasked server text frame. Read the length header to locate the payload.
/// The two-byte length can contain a brace byte.
fn responsePayload(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2) return error.InvalidResponse;
    const indicator = bytes[1] & 0x7f; // The server sends an unmasked frame.
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
    if (payload_len > bytes.len - offset) return error.InvalidResponse; // Subtract first to avoid an overflow.
    return bytes[offset .. offset + payload_len];
}

/// Parse a response frame and return its `result` object. Tests call this function.
fn responseResult(arena: std.mem.Allocator, bytes: []const u8) !std.json.ObjectMap {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try responsePayload(bytes), .{});
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    return switch (object.get("result") orelse return error.InvalidResponse) {
        .object => |result| result,
        else => error.InvalidResponse,
    };
}

fn responseNextCursor(arena: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    const result = try responseResult(arena, bytes);
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
    const result = try responseResult(arena.allocator(), bytes);
    return switch (result.get("items") orelse return error.InvalidResponse) {
        .array => |items| items.items.len,
        else => error.InvalidResponse,
    };
}

fn responseUpdatedAt(bytes: []const u8) ![2]u64 {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try responseResult(arena.allocator(), bytes);
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
    // The clock returns a time after this 2023 timestamp.
    try std.testing.expect(fixture.state.nowMillis() > 1_700_000_000_000);
    // A fresh daemon returns an empty workspace list and a zero session revision.
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

    try std.testing.expectEqual(@as(u64, 1), try database.session.count(&fixture.state.db, fixture.allocator(), .{}));
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
    // The default home is "/home/test"; use its basename as the title.
    try std.testing.expect(std.mem.indexOf(u8, out1.buffered(), "\"title\":\"test\"") != null);

    var buf2: [4096]u8 = undefined;
    var out2: std.Io.Writer = .fixed(&buf2);
    _ = try handleRequest(&fixture.state, fixture.conn, &out2, empty_params);

    try std.testing.expectEqual(@as(u64, 2), try database.session.count(&fixture.state.db, fixture.allocator(), .{}));
}

test "session.create seeds the system prompt from the yuked.json default" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    fixture.state.defaults = .{ .system_prompt = "be terse" };

    // No request prompt uses the daemon default; a request prompt overrides it.
    const seeded = try handlers.sessionCreate(&fixture.state, fixture.allocator(), .{});
    const seeded_config = try handlers.sessionConfig(&fixture.state, fixture.allocator(), .{ .session_id = seeded.session.id });
    try std.testing.expectEqualStrings("be terse", seeded_config.system_prompt.?);
    const overridden = try handlers.sessionCreate(&fixture.state, fixture.allocator(), .{ .system_prompt = "be expansive" });
    const overridden_config = try handlers.sessionConfig(&fixture.state, fixture.allocator(), .{ .session_id = overridden.session.id });
    try std.testing.expectEqualStrings("be expansive", overridden_config.system_prompt.?);
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

    const cursor = (try responseNextCursor(fixture.allocator(), first)) orelse return error.MissingCursor;
    var second_frame: [8192]u8 = undefined;
    const second_request = try std.fmt.bufPrint(
        &second_frame,
        "{{\"id\":\"5\",\"method\":\"session.list\",\"params\":{{\"limit\":2,\"cursor\":\"{s}\"}}}}",
        .{cursor},
    );
    var second_buffer: [8192]u8 = undefined;
    const second = try call(&fixture, second_request, &second_buffer);
    try std.testing.expectEqual(@as(usize, 1), try responseItemCount(second));
    try std.testing.expect((try responseNextCursor(fixture.allocator(), second)) == null);

    // Each session appears on exactly one page. The cursor advances through each row once.
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

    const workspace = try database.workspace.resolve(
        &fixture.state.db,
        fixture.allocator(),
        [_]u8{9} ** 16,
        "/scope/one",
        "one",
        "/scope/one",
    );
    var scope_buffer: std.Io.Writer.Allocating = .init(fixture.allocator());
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
    const cursor = (try responseNextCursor(fixture.allocator(), first)) orelse return error.MissingCursor;

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
    const a = fixture.allocator();

    const created = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/p", .model = "opus", .reasoning = "high" });
    // Read the initial config by its revision and as the current config.
    const cfg = try handlers.sessionConfig(&fixture.state, a, .{ .session_id = created.session.id, .config_rev = 0 });
    try std.testing.expectEqual(@as(u64, 0), cfg.config.config_rev);
    try std.testing.expectEqualStrings("opus", cfg.config.model);
}

test "session.create canonicalizes the workspace so path spellings dedup to one workspace" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // Three spellings of the same directory share one workspace id.
    const one = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/home/u/proj" });
    const two = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/home/u/proj/" });
    const three = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/home/u/x/../proj" });
    try std.testing.expectEqualSlices(u8, &one.session.workspace_id.raw, &two.session.workspace_id.raw);
    try std.testing.expectEqualSlices(u8, &one.session.workspace_id.raw, &three.session.workspace_id.raw);

    // A genuinely different directory gets its own workspace.
    const other = try handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "/home/u/other" });
    try std.testing.expect(!std.mem.eql(u8, &one.session.workspace_id.raw, &other.session.workspace_id.raw));
}

test "session.create rejects a relative workspace path" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    try std.testing.expectError(error.RootNotAbsolute, handlers.sessionCreate(&fixture.state, a, .{ .workspace_path = "relative/dir" }));
}

test "session.history returns committed messages oldest-first with their configs" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/p", .model = "opus", .reasoning = "high" });

    const user: wire.message.Message = .{ .user = .{ .id = 1, .content = &.{}, .input_id = 1, .time = .{ .created_at_ms = 150 } } };
    const assistant: wire.message.Message = .{
        .assistant = .{
            .id = 2,
            .run_id = 1,
            .config_rev = 0, // References the initial record from recordInitial.
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
    try std.testing.expectEqual(@as(u64, 1), hist.messages[0].user.id); // The history lists the oldest message first.
    try std.testing.expectEqual(@as(u64, 2), hist.messages[1].assistant.id);
    try std.testing.expect(!hist.has_more);
    // The assistant turn uses config revision 0. The history result resolves that revision.
    try std.testing.expectEqual(@as(usize, 1), hist.configs.len);
    try std.testing.expectEqual(@as(u64, 0), hist.configs[0].config_rev);
}

test "session reads reject an unknown session and an unknown revision" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

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
    // A printable 16-byte id decodes successfully. The session lookup returns no match.
    const written = try call(&fixture,
        \\{"id":"1","method":"session.config","params":{"session_id":"0123456789abcdef0123456789abcdef"}}
    , &buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "-31000") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"1\"") != null);
}

test "a completed run drains every queued input into one next run" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/drain", .model = "mock/fast" });
    const first = try sendText(&fixture, a, sid, "one");
    try std.testing.expect(first == .started);
    const second = try sendText(&fixture, a, sid, "two");
    const third = try sendText(&fixture, a, sid, "three");
    try std.testing.expect(second == .queued);
    try std.testing.expect(third == .queued);
    try std.testing.expectEqual(@as(usize, 2), fixture.state.sessions.get(sid).?.session.queue.depth());

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
    try std.testing.expectEqualStrings("mock/fast", history[1].assistant.provenance.?.model);
}

test "a durable queue starts before a new idle input" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/resume", .model = "mock/fast" });
    const old_content = [_]wire.content.ContentPart{.{ .text = .{ .text = "old" } }};
    const new_content = [_]wire.content.ContentPart{.{ .text = .{ .text = "new" } }};
    try fixture.state.db.conn.execNoArgs("BEGIN IMMEDIATE");
    const old = try database.input.enqueue(&fixture.state.db, a, sid.raw, fixture.state.newId(), 100, &old_content, 100);
    try fixture.state.db.conn.execNoArgs("COMMIT");
    // The durable input loads into the queue when the runtime activates on the send below.
    const runtime = try fixture.state.sessions.getOrCreate(sid);

    const accepted = try sendInputDirect(&fixture.state, a, .{
        .session_id = sid,
        .input = .{ .content = .{ .content = &new_content } },
    });
    try std.testing.expect(accepted == .queued);
    try std.testing.expectEqual(old.input.input_id, runtime.active.?.handle.input_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.session.queue.depth());

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
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/fault", .model = "mock/fast" });
    const content = [_]wire.content.ContentPart{.{ .text = .{ .text = "first" } }};
    const old = try engine_run.beginTurn(&fixture.state.db, fixture.state.io, a, sid.raw, &content, 0);
    const rt = try fixture.state.sessions.getOrCreate(sid);
    rt.faulted = true;
    fixture.state.sessions.evictIfIdle(sid);
    try std.testing.expect(fixture.state.sessions.get(sid) == rt);

    try std.testing.expectError(error.RuntimeFailed, sendInputDirect(&fixture.state, a, .{
        .session_id = sid,
        .input = .{ .content = .{ .content = &content } },
    }));
    try std.testing.expectEqual(@as(?u64, old.handle.started.run_id), (try database.session.snapshot(&fixture.state.db, a, sid.raw)).?.open_run_id);
    try std.testing.expectEqual(@as(i64, 1), try countNamedEvents(&fixture.state.db, "run.started"));
}

test "cancel input and cancel run preserve exact durable outcomes" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/cancel", .model = "mock/fast" });
    const started = (try sendText(&fixture, a, sid, "input")).started;
    const queued_one = (try sendText(&fixture, a, sid, "input")).queued;
    const queued_two = (try sendText(&fixture, a, sid, "input")).queued;

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

/// A terminal SSE reply. The parked reader returns it, so the stream ends the way a real one ends.
const parked_done =
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// A transport parks its read until the reader task cancels it. `entered` signals the parked read.
const BlockingTransport = struct {
    entered: *zio.ResetEvent,
    gate: *zio.ResetEvent,
    interrupted: *bool, // Set this flag when the parked read catches error.Canceled.
    deinitialized: ?*bool = null,

    fn transportFor(self: *BlockingTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: transport.Transport.VTable = .{ .open = open };

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: transport.Request, info: *transport.AttemptInfo) anyerror!transport.ResponseBody {
        _ = request;
        _ = info;
        const self: *BlockingTransport = @ptrCast(@alignCast(ctx));
        const reader = try arena.create(Reader);
        reader.* = .{
            .entered = self.entered,
            .gate = self.gate,
            .interrupted = self.interrupted,
            .deinitialized = self.deinitialized,
        };
        return .{ .ctx = reader, .vtable = &Reader.vtable };
    }

    const Reader = struct {
        entered: *zio.ResetEvent,
        gate: *zio.ResetEvent,
        interrupted: *bool,
        deinitialized: ?*bool,
        sent: bool = false,

        const vtable: transport.ResponseBody.VTable = .{ .read = read, .deinit = deinit };

        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *Reader = @ptrCast(@alignCast(ctx));
            if (self.sent) return 0;
            self.entered.set(); // The read parks here, so the canceler can now fire.
            self.gate.wait() catch |err| { // Park until the reader task cancels this read.
                if (err == error.Canceled) self.interrupted.* = true;
                return err;
            };
            // A complete stream ends the round. A truncated one would ask the retry loop to repeat.
            self.sent = true;
            @memcpy(buf[0..parked_done.len], parked_done);
            return parked_done.len;
        }
        fn deinit(ctx: *anyopaque) void {
            const self: *Reader = @ptrCast(@alignCast(ctx));
            if (self.deinitialized) |deinitialized| deinitialized.* = true;
        }
    };
};

fn cancelWhenBlocked(state: *State, sid: wire.ids.SessionId, run_id: u64, entered: *zio.ResetEvent) !void {
    try entered.wait(); // Wait until the provider read parks.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try handlers.sessionCancelRun(state, arena.allocator(), .{ .session_id = sid, .run_id = run_id });
    try launchUntilIdle(state, sid);
}

test "cancel run interrupts a blocked provider read" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var interrupted = false;
    var deinitialized = false;
    var blocking: BlockingTransport = .{
        .entered = &entered,
        .gate = &gate,
        .interrupted = &interrupted,
        .deinitialized = &deinitialized,
    };
    fixture.state.route_transport = blocking.transportFor();

    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/block", .model = "mock/fast" });
    const started = (try sendText(&fixture, a, sid, "hi")).started;

    // The run parks in the read. A separate task cancels it during the read.
    var driver = try fixture.rt.spawn(cancelWhenBlocked, .{ &fixture.state, sid, started.run_id, &entered });
    try driver.join();

    try std.testing.expect(interrupted); // The cancel interrupted the parked read before it drained.
    try std.testing.expect(deinitialized); // The reader joined and released the body before the run became idle.
    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .canceled);
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqual(wire.enums.StopReason.canceled, history[1].assistant.finish.?);
    try std.testing.expect((try database.session.snapshot(&fixture.state.db, a, sid.raw)).?.open_run_id == null);
}

/// Assert the live draft is reachable from the runtime while a run streams. Then release the read.
fn assertDraftReachable(state: *State, sid: wire.ids.SessionId, entered: *zio.ResetEvent, gate: *zio.ResetEvent) !void {
    try entered.wait(); // The read parked. The run opened its draft.
    const rt = state.sessions.get(sid) orelse return error.NoRuntime;
    try std.testing.expect(rt.active != null);
    try std.testing.expect(rt.session.active != null);
    try std.testing.expectEqual(rt.active.?.progress.current.?.message_id, rt.session.active.?.message_id);
    gate.set(); // Let the read end so the run reaches its terminal state.
    try launchUntilIdle(state, sid);
}

/// Resync during a parked run and assert the live draft is serialized. Then release the read.
fn resyncWhileBlocked(state: *State, sid: wire.ids.SessionId, entered: *zio.ResetEvent, gate: *zio.ResetEvent) !void {
    try entered.wait(); // The read parked. The run opened its draft.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try handlers.sessionResync(state, arena.allocator(), .{ .session_id = sid, .limit = null });
    try std.testing.expect(result.active != null); // The live draft is present.
    try std.testing.expect(result.item.activity.state != .idle); // A run streams.
    gate.set(); // Let the read end so the run reaches its terminal state.
    try launchUntilIdle(state, sid);
}

test "resync during a run serializes the live draft" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var interrupted = false;
    var blocking: BlockingTransport = .{ .entered = &entered, .gate = &gate, .interrupted = &interrupted };
    fixture.state.route_transport = blocking.transportFor();

    const a = fixture.allocator();
    const sid = try createSession(&fixture, a, .{ .workspace_path = "/resync-live", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var driver = try fixture.rt.spawn(resyncWhileBlocked, .{ &fixture.state, sid, &entered, &gate });
    try driver.join();
}

test "the live draft is reachable from the runtime during a run" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var interrupted = false;
    var blocking: BlockingTransport = .{ .entered = &entered, .gate = &gate, .interrupted = &interrupted };
    fixture.state.route_transport = blocking.transportFor();

    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/reach", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    // A driver inspects the runtime while the run parks in the provider read.
    // The driver holds the reachability assertions. The leak check proves the draft is freed once.
    var driver = try fixture.rt.spawn(assertDraftReachable, .{ &fixture.state, sid, &entered, &gate });
    try driver.join();
}

test "activation hydrates the committed window and the durable cursor" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/hydrate", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");
    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    // The turn committed a user message and an assistant message, then the idle runtime was evicted.
    try std.testing.expect(fixture.state.sessions.get(sid) == null);
    const rt = try fixture.state.activate(sid);
    const hw = (try database.event.highWater(&fixture.state.db, a, sid.raw)).?;
    try std.testing.expectEqual(hw.seq_high, rt.session.base_seq);
    try std.testing.expectEqual(@as(usize, 2), rt.session.committed.list.items.len);
    try std.testing.expect(rt.session.committed.newestId() != null);
}

test "resync of an idle session returns its committed window" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/resync-idle", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");
    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    // The idle session was evicted. Resync hydrates a transient projection from SQLite.
    try std.testing.expect(fixture.state.sessions.get(sid) == null);
    const result = try handlers.sessionResync(&fixture.state, a, .{ .session_id = sid, .limit = null });
    try std.testing.expect(result.active == null);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len); // the user and the assistant message
    try std.testing.expect(result.messages[0] == .user);
    try std.testing.expectEqualStrings("hi", result.messages[0].user.content[0].text.text);
    try std.testing.expect(result.messages[1] == .assistant);
    try std.testing.expect(result.base_seq > 0);
    try std.testing.expect(result.highest_finalized_message_id != null);
    try std.testing.expect(!result.has_more);
    try std.testing.expectEqual(@as(u64, 0), result.item.activity.queued);
    try std.testing.expect(result.item.activity.state == .idle);
}

test "resync limits the window to the newest page" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/resync-page", .model = "mock/fast" });
    // Two turns commit four messages.
    inline for (.{ "one", "two" }) |text| {
        const content = [_]wire.content.ContentPart{.{ .text = .{ .text = text } }};
        _ = try sendInputDirect(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &content } } });
        var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
        try launch.join();
    }
    const result = try handlers.sessionResync(&fixture.state, a, .{ .session_id = sid, .limit = 2 });
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expect(result.has_more); // two older messages remain
    try std.testing.expect(result.messages[0] == .user); // the newest page starts at the last user message
    try std.testing.expectEqualStrings("two", result.messages[0].user.content[0].text.text);
}

test "resync validates the limit and the session id" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/resync-bad", .model = "mock/fast" });
    try std.testing.expectError(error.BadRequest, handlers.sessionResync(&fixture.state, a, .{ .session_id = sid, .limit = 0 }));
    try std.testing.expectError(error.BadRequest, handlers.sessionResync(&fixture.state, a, .{ .session_id = sid, .limit = wire.meta.limits.max_page_size + 1 }));
    const missing: wire.ids.SessionId = .bytes(@splat(9));
    try std.testing.expectError(error.UnknownSession, handlers.sessionResync(&fixture.state, a, .{ .session_id = missing, .limit = null }));
}

// This reasoning turn has one thinking block, one signature, and a clean stop.
const reasoning_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"because\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":8}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "a reasoning block stop finalizes the signature into the committed message" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var canned: provider.transport.CannedTransport = .{ .bytes = reasoning_reply };
    fixture.state.route_transport = canned.transport();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/reason", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    const parts = history[1].assistant.content;
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expect(parts[0] == .reasoning);
    try std.testing.expectEqualStrings("because", parts[0].reasoning.text);
    try std.testing.expectEqualStrings("sig", parts[0].reasoning.signature); // The finalization event folded the signature.
}

// A tool-use turn: one tool_use block with a streamed argument, then a clean tool_use stop.
const tool_use_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"x\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// A final text turn: one text block with a streamed delta, then an end-turn stop.
const final_text_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// A turn that reports cached and cache-created prompt tokens, so the gauge has every subset.
const cached_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":13}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Install `seq`, run one full turn, and return when the session settles.
fn runOneTurn(fixture: *TestState, a: std.mem.Allocator, path: []const u8, seq: *provider.transport.ScriptedTransport) !wire.ids.SessionId {
    fixture.state.route_transport = seq.transport();
    const sid = try createSession(fixture, a, .{ .workspace_path = path, .model = "mock/fast" });
    _ = try sendText(fixture, a, sid, "hi");
    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();
    return sid;
}

test "session.list reports the context gauge and the lifetime totals after a turn" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = provider.transport.replies(&.{cached_reply});
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    const sid = try runOneTurn(&fixture, a, "/gauge-list", &seq);

    const listed = try handlers.sessionList(&fixture.state, a, .{});
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    const item = listed.items[0];
    try std.testing.expectEqualSlices(u8, &sid.raw, &item.session.id.raw);

    // The gauge is the newest assistant turn, not a zero and not the lifetime sum.
    try std.testing.expectEqual(@as(u64, 40), item.activity.context_usage.input); // 7 + 20 + 13
    try std.testing.expectEqual(@as(u64, 5), item.activity.context_usage.output);
    try std.testing.expectEqual(@as(u64, 20), item.activity.context_usage.cache_read);
    try std.testing.expectEqual(@as(u64, 13), item.activity.context_usage.cache_write);

    // The lifetime totals carry the same one turn, and input holds the cache subsets.
    try std.testing.expectEqual(@as(u64, 40), item.session.usage_total.input);
    try std.testing.expectEqual(@as(u64, 5), item.session.usage_total.output);
    try std.testing.expectEqual(@as(u64, 20), item.session.usage_total.cache_read);
    try std.testing.expectEqual(@as(u64, 13), item.session.usage_total.cache_write);
    try std.testing.expectEqual(@as(u64, 2), item.session.message_count);
}

test "resync reports the context gauge of an idle session" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = provider.transport.replies(&.{cached_reply});
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    const sid = try runOneTurn(&fixture, a, "/gauge-resync", &seq);

    // The idle runtime was evicted, so this resync hydrates a transient projection.
    try std.testing.expect(fixture.state.sessions.get(sid) == null);
    const result = try handlers.sessionResync(&fixture.state, a, .{ .session_id = sid, .limit = null });
    try std.testing.expect(result.item.activity.state == .idle);
    try std.testing.expectEqual(@as(u64, 40), result.item.activity.context_usage.input);
    try std.testing.expectEqual(@as(u64, 20), result.item.activity.context_usage.cache_read);
    try std.testing.expectEqual(@as(u64, 13), result.item.activity.context_usage.cache_write);
}

test "the lifetime totals stay monotonic over two turns" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = provider.transport.replies(&.{ cached_reply, cached_reply });
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    const sid = try runOneTurn(&fixture, a, "/gauge-restart", &seq);

    _ = try sendText(&fixture, a, sid, "again");
    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    // Two turns folded once each. The durable row holds the sum.
    const snap = (try database.session.snapshot(&fixture.state.db, a, sid.raw)).?;
    try std.testing.expectEqual(@as(u64, 80), snap.usage_input_total);
    try std.testing.expectEqual(@as(u64, 10), snap.usage_output_total);
    try std.testing.expectEqual(@as(u64, 40), snap.usage_cache_read_total);
    try std.testing.expectEqual(@as(u64, 26), snap.usage_cache_write_total);
    try std.testing.expectEqual(@as(u64, 4), snap.message_count);
}

test "a turn announces its activity and its summary" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var log = BroadcastLog.init();
    defer log.deinit();
    const a = fixture.allocator();

    const steps = provider.transport.replies(&.{cached_reply});
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();
    // Register before the session exists, so the create announcement also lands in the outbox.
    try fixture.register();
    const sid = try createSession(&fixture, a, .{ .workspace_path = "/gauge-activity", .model = "mock/fast" });
    try fixture.subscribe(sid);
    _ = try sendText(&fixture, a, sid, "hi");
    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();
    try log.drain(fixture.conn);

    var activities: usize = 0;
    var summaries: usize = 0;
    var settled_idle = false;
    var final_gauge: u64 = 0;
    var counts: [8]u64 = undefined;
    for (log.events.items) |bc| switch (bc) {
        .session_activity_changed_data => |d| {
            activities += 1;
            settled_idle = d.activity.state == .idle;
            final_gauge = d.activity.context_usage.input;
        },
        .session_summary_changed_data => |d| {
            try std.testing.expectEqual(@as(u64, @intCast(summaries + 1)), d.revision); // No revision repeats or is skipped.
            try std.testing.expect(summaries < counts.len);
            counts[summaries] = d.session.message_count;
            summaries += 1;
        },
        else => {},
    };

    // The create, the user commit, and the assistant commit each announce a growing summary.
    try std.testing.expect(summaries >= 3);
    for (counts[1..summaries], counts[0 .. summaries - 1]) |now, before| try std.testing.expect(now >= before);
    // The run start, the text block, and the settle each announce activity.
    try std.testing.expect(activities >= 3);
    // The last announcement reports an idle session whose gauge holds the committed turn.
    try std.testing.expect(settled_idle);
    try std.testing.expectEqual(@as(u64, 40), final_gauge);
}

test "a tool_use round commits, then a second round streams the final answer" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // Round 1 asks for the read tool; round 2 answers with text. Capture each request body.
    const steps = provider.transport.replies(&.{ tool_use_reply, final_text_reply });
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps, .capture = a };
    fixture.state.route_transport = seq.transport();

    // The read tool resolves its path against the session workspace.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x", .data = "hello\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const sid = try createSession(&fixture, a, .{ .workspace_path = root, .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    // Two assistant messages: the tool round and the final answer, plus the user message.
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 3), history.len);

    const tool_parts = history[1].assistant.content;
    try std.testing.expectEqual(@as(usize, 1), tool_parts.len);
    try std.testing.expect(tool_parts[0] == .tool);
    try std.testing.expectEqualStrings("read", tool_parts[0].tool.name);
    try std.testing.expectEqual(std.meta.activeTag(tool_parts[0].tool.state), .completed);
    try std.testing.expectEqualStrings("1: hello", tool_parts[0].tool.state.completed.output);

    const final_parts = history[2].assistant.content;
    try std.testing.expectEqual(@as(usize, 1), final_parts.len);
    try std.testing.expect(final_parts[0] == .text);
    try std.testing.expectEqualStrings("done", final_parts[0].text.text);

    // The transport opened once for each round, and the second request carries the tool call plus its
    // derived tool_result so the model sees the read output.
    try std.testing.expectEqual(@as(usize, 2), seq.index);
    try std.testing.expectEqual(@as(usize, 2), seq.requests.items.len);
    const round_two = seq.requests.items[1];
    try std.testing.expect(std.mem.indexOf(u8, round_two, "tool_use") != null);
    try std.testing.expect(std.mem.indexOf(u8, round_two, "tool_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, round_two, "1: hello") != null);

    // Exactly one run.done ends the turn, and it counts both rounds.
    try std.testing.expectEqual(@as(i64, 1), try countNamedEvents(&fixture.state.db, "run.done"));
    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .turn);
    try std.testing.expectEqual(@as(u64, 2), done.outcome.turn.rounds);
}

// One tool_use block in a round: read "a".
const one_tool_reply_a =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// Two sequential tool_use blocks in one round: read "a", then read "b".
const two_tool_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"b\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// Four gates drive two tool calls. A test controls when each call enters and when it returns.
const BatchGates = struct {
    entered_a: zio.ResetEvent = .init,
    entered_b: zio.ResetEvent = .init,
    release_a: zio.ResetEvent = .init,
    release_b: zio.ResetEvent = .init,
};

// This host gates each read on its path. A test controls when each read returns.
const GatedHost = struct {
    gates: *BatchGates,

    const vtable: tools.ToolHost.VTable = blk: {
        var v = test_host.unsupported; // The gated tests call only readRange.
        v.readRange = readRange;
        break :blk v;
    };
    fn host(self: *GatedHost) tools.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn readRange(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, range: tools.Range, limits: tools.ReadLimits) tools.HostError!tools.RangeRead {
        _ = .{ range, limits };
        const self: *GatedHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, path, "a")) {
            self.gates.entered_a.set();
            self.gates.release_a.wait() catch return error.Canceled;
            return .{ .text = try scratch.dupe(u8, "alpha\n") };
        }
        self.gates.entered_b.set();
        self.gates.release_b.wait() catch return error.Canceled;
        return .{ .text = try scratch.dupe(u8, "beta\n") };
    }
};

// Release each tool call in turn. The second call must not enter before the first one returns.
fn gatedBatchDriver(state: *State, sid: wire.ids.SessionId, gates: *BatchGates) !void {
    try gates.entered_a.wait();
    try std.testing.expect(!gates.entered_b.isSet()); // The second call waits for the first one.
    gates.release_a.set();
    try gates.entered_b.wait();
    gates.release_b.set();
    try launchUntilIdle(state, sid);
}

test "a tool round runs its calls one at a time in provider order" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // Round 1 asks for two reads; round 2 answers with text.
    const steps = provider.transport.replies(&.{ two_tool_reply, final_text_reply });
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();
    var gates: BatchGates = .{};
    var gated: GatedHost = .{ .gates = &gates };
    fixture.state.tool_host = gated.host();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/batch", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var driver = try fixture.rt.spawn(gatedBatchDriver, .{ &fixture.state, sid, &gates });
    try driver.join();

    // The tool round holds both parts in provider order, each with its own read output.
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 3), history.len);
    const parts = history[1].assistant.content;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expect(parts[0] == .tool and parts[1] == .tool);
    try std.testing.expectEqual(std.meta.activeTag(parts[0].tool.state), .completed);
    try std.testing.expectEqual(std.meta.activeTag(parts[1].tool.state), .completed);
    try std.testing.expectEqualStrings("1: alpha", parts[0].tool.state.completed.output); // read "a" first
    try std.testing.expectEqualStrings("1: beta", parts[1].tool.state.completed.output); // read "b" second
}

// Wait until the active draft's tool part at `index` reaches the completed state.
fn yieldUntilCompleted(state: *State, sid: wire.ids.SessionId, index: usize) !void {
    var attempts: usize = 0;
    while (attempts < 10_000) : (attempts += 1) {
        const rt = state.sessions.get(sid) orelse return error.NoRuntime;
        if (rt.session.active) |d| {
            if (index < d.parts.items.len and d.parts.items[index] == .tool and
                std.meta.activeTag(d.parts.items[index].tool.state) == .completed) return;
        }
        try zio.yield();
    }
    return error.NotCompleted;
}

// Cancel the run while the first tool call parks in its read. The second call never enters.
fn cancelBlockedBatchDriver(state: *State, sid: wire.ids.SessionId, run_id: u64, gates: *BatchGates) !void {
    try gates.entered_a.wait();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try handlers.sessionCancelRun(state, arena.allocator(), .{ .session_id = sid, .run_id = run_id });
    try launchUntilIdle(state, sid);
}

test "cancel run cancels the blocked tool call and every pending one" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = provider.transport.replies(&.{two_tool_reply});
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();
    var gates: BatchGates = .{};
    var gated: GatedHost = .{ .gates = &gates }; // No gate opens, so the first call stays blocked.
    fixture.state.tool_host = gated.host();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/batch-cancel", .model = "mock/fast" });
    const started = (try sendText(&fixture, a, sid, "hi")).started;

    var driver = try fixture.rt.spawn(cancelBlockedBatchDriver, .{ &fixture.state, sid, started.run_id, &gates });
    try driver.join(); // The run must reach idle: the blocked call returned.

    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .canceled);
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    const parts = history[1].assistant.content;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(std.meta.activeTag(parts[0].tool.state), .canceled);
    try std.testing.expectEqual(std.meta.activeTag(parts[1].tool.state), .canceled);
}

// Let the first tool finish, then cancel the run while the second parks in its read.
fn cancelOneDoneDriver(state: *State, sid: wire.ids.SessionId, run_id: u64, gates: *BatchGates) !void {
    try gates.entered_a.wait();
    gates.release_a.set(); // Let the first call finish its read and record its result.
    try yieldUntilCompleted(state, sid, 0);
    try gates.entered_b.wait(); // The second call now parks in its read.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try handlers.sessionCancelRun(state, arena.allocator(), .{ .session_id = sid, .run_id = run_id });
    try launchUntilIdle(state, sid);
}

test "cancel run keeps a finished tool and cancels the blocked one" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = provider.transport.replies(&.{two_tool_reply});
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();
    var gates: BatchGates = .{};
    var gated: GatedHost = .{ .gates = &gates }; // Only gate a opens, so the second call blocks.
    fixture.state.tool_host = gated.host();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/batch-mixed", .model = "mock/fast" });
    const started = (try sendText(&fixture, a, sid, "hi")).started;

    var driver = try fixture.rt.spawn(cancelOneDoneDriver, .{ &fixture.state, sid, started.run_id, &gates });
    try driver.join();

    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .canceled);
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    const parts = history[1].assistant.content;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(std.meta.activeTag(parts[0].tool.state), .completed); // the first call finished
    try std.testing.expectEqualStrings("1: alpha", parts[0].tool.state.completed.output);
    try std.testing.expectEqual(std.meta.activeTag(parts[1].tool.state), .canceled); // the second call blocked
}

// Steer a new input while the tool leg parks, then release it. The input must queue, not start.
fn steerWhileToolRuns(state: *State, sid: wire.ids.SessionId, gates: *BatchGates) !void {
    try gates.entered_a.wait(); // The tool call parks in the read, so the run is active.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const steer = [_]wire.content.ContentPart{.{ .text = .{ .text = "steer" } }};
    // A run is active, so the input queues.
    try std.testing.expect((try sendInputDirect(state, arena.allocator(), .{ .session_id = sid, .input = .{ .content = .{ .content = &steer } } })) == .queued);
    try std.testing.expectEqual(@as(usize, 1), state.sessions.get(sid).?.session.queue.depth());
    gates.release_a.set(); // Let the tool finish. The turn then completes and drains the queue.
    try launchUntilIdle(state, sid);
}

test "an input queued while tools run drains only after the turn commits" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // Turn 1: a tool round then a final answer. Turn 2 (steered): a final answer.
    const steps = provider.transport.replies(&.{ one_tool_reply_a, final_text_reply, final_text_reply });
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();
    var gates: BatchGates = .{};
    var gated: GatedHost = .{ .gates = &gates };
    fixture.state.tool_host = gated.host();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/steer", .model = "mock/fast" });
    try std.testing.expect((try sendText(&fixture, a, sid, "hi")) == .started);

    var driver = try fixture.rt.spawn(steerWhileToolRuns, .{ &fixture.state, sid, &gates });
    try driver.join();

    // Two runs: the tool turn, then the steered turn. The queue drained only after the first turn.
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "run.started"));
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "run.done"));
    try std.testing.expectEqual(@as(i64, 1), try countNamedEvents(&fixture.state.db, "input.queued"));

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 5), history.len);
    try std.testing.expectEqualStrings("hi", history[0].user.content[0].text.text);
    try std.testing.expect(history[1].assistant.content[0] == .tool); // the tool round
    try std.testing.expectEqual(std.meta.activeTag(history[1].assistant.content[0].tool.state), .completed);
    try std.testing.expectEqualStrings("done", history[2].assistant.content[0].text.text); // turn 1 answer
    try std.testing.expectEqualStrings("steer", history[3].user.content[0].text.text); // the queued input
    try std.testing.expectEqualStrings("done", history[4].assistant.content[0].text.text); // turn 2 answer
}

// Close the parked text block and end the turn. It follows `stream_prefix`.
const stream_finish_suffix =
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// Steer a new input while the provider stream parks, then release it. The input must queue.
fn steerWhileStreaming(state: *State, sid: wire.ids.SessionId, entered: *zio.ResetEvent, gate: *zio.ResetEvent) !void {
    try entered.wait(); // The stream parked mid-reply, so the run is active.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const steer = [_]wire.content.ContentPart{.{ .text = .{ .text = "steer" } }};
    // A run is active, so the input queues.
    try std.testing.expect((try sendInputDirect(state, arena.allocator(), .{ .session_id = sid, .input = .{ .content = .{ .content = &steer } } })) == .queued);
    try std.testing.expectEqual(@as(usize, 1), state.sessions.get(sid).?.session.queue.depth());
    gate.set(); // Let the stream finish. The turn then completes and drains the queue.
    try launchUntilIdle(state, sid);
}

test "an input queued while the provider streams drains after the turn" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var transport_impl = StreamThenParkTransport{ .prefix = stream_prefix, .suffix = stream_finish_suffix, .entered = &entered, .gate = &gate };
    fixture.state.route_transport = transport_impl.transportFor();

    const a = fixture.allocator();
    const sid = try createSession(&fixture, a, .{ .workspace_path = "/steer-stream", .model = "mock/fast" });
    try std.testing.expect((try sendText(&fixture, a, sid, "hi")) == .started);

    var driver = try fixture.rt.spawn(steerWhileStreaming, .{ &fixture.state, sid, &entered, &gate });
    try driver.join();

    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "run.started"));
    try std.testing.expectEqual(@as(i64, 2), try countNamedEvents(&fixture.state.db, "run.done"));
    try std.testing.expectEqual(@as(i64, 1), try countNamedEvents(&fixture.state.db, "input.queued"));

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 4), history.len);
    try std.testing.expectEqualStrings("hi", history[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("hello", history[1].assistant.content[0].text.text); // turn 1 answer
    try std.testing.expectEqualStrings("steer", history[2].user.content[0].text.text); // the queued input
    try std.testing.expect(history[3] == .assistant); // turn 2 answer
}

test "the queue rejects input past the max" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/queue-full", .model = "mock/fast" });
    // Start a run; it stays active while the test fills the queue synchronously.
    try std.testing.expect((try sendText(&fixture, a, sid, "0")) == .started);

    const cap: usize = @intCast(wire.meta.limits.max_queued_inputs);
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        const c = [_]wire.content.ContentPart{.{ .text = .{ .text = "q" } }};
        try std.testing.expect((try sendInputDirect(&fixture.state, a, .{ .session_id = sid, .input = .{ .content = .{ .content = &c } } })) == .queued);
    }
    try std.testing.expectEqual(cap, fixture.state.sessions.get(sid).?.session.queue.depth());

    // One input past the limit is rejected and adds no event.
    try std.testing.expectError(error.QueueFull, sendText(&fixture, a, sid, "over"));
    try std.testing.expectEqual(cap, fixture.state.sessions.get(sid).?.session.queue.depth());

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join(); // Drain cleanly.
}

test "a finite max_rounds ends the turn after the capped tool round" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // Round 1 asks for a tool. The cap of 1 ends the turn before a second round. A sentinel second
    // reply would let a leaked round complete, so the capture proves only one request opened.
    const steps = provider.transport.replies(&.{ one_tool_reply_a, final_text_reply });
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps, .capture = a };
    fixture.state.route_transport = seq.transport();
    var gates: BatchGates = .{};
    gates.release_a.set(); // The read never blocks.
    var gated: GatedHost = .{ .gates = &gates };
    fixture.state.tool_host = gated.host();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/max-rounds", .model = "mock/fast", .max_rounds = 1 });
    _ = try sendText(&fixture, a, sid, "hi");

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    try std.testing.expectEqual(@as(usize, 1), seq.requests.items.len); // Only one request opened.
    try std.testing.expectEqual(@as(i64, 1), try countNamedEvents(&fixture.state.db, "run.done"));
    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .failed);
    try std.testing.expectEqual(wire.enums.RunErrorCode.max_rounds, done.outcome.failed.code);
    try std.testing.expect((try database.session.snapshot(&fixture.state.db, a, sid.raw)).?.open_run_id == null);

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqual(wire.enums.StopReason.tool_calls, history[1].assistant.finish.?);
    try std.testing.expect(history[1].assistant.content[0] == .tool);
    try std.testing.expectEqual(std.meta.activeTag(history[1].assistant.content[0].tool.state), .completed);
}

test "max_rounds of 2 allows a tool round then a final answer" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // A tool round then a final answer is two rounds, so the cap of 2 does not fire.
    const steps = provider.transport.replies(&.{ one_tool_reply_a, final_text_reply });
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();
    var gates: BatchGates = .{};
    gates.release_a.set();
    var gated: GatedHost = .{ .gates = &gates };
    fixture.state.tool_host = gated.host();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/max-rounds-2", .model = "mock/fast", .max_rounds = 2 });
    _ = try sendText(&fixture, a, sid, "hi");

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .turn); // The turn ends normally, not capped.
    try std.testing.expectEqual(@as(u64, 2), done.outcome.turn.rounds);

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 3), history.len);
    try std.testing.expectEqualStrings("done", history[2].assistant.content[0].text.text);
}

test "max_rounds of 1 does not cap a plain text turn" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // A plain text answer is one round through the final path, so the cap never applies.
    const steps = provider.transport.replies(&.{final_text_reply});
    var seq: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = seq.transport();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/max-rounds-text", .model = "mock/fast", .max_rounds = 1 });
    _ = try sendText(&fixture, a, sid, "hi");

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    const row = (try fixture.state.db.conn.row("SELECT payload FROM events WHERE name = 'run.done'", .{})) orelse return error.NoRow;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(wire.run.RunDoneData, a, row.text(0), .{});
    try std.testing.expect(done.outcome == .turn);
    try std.testing.expectEqual(@as(u64, 1), done.outcome.turn.rounds);

    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("done", history[1].assistant.content[0].text.text);
}

// A prefix with three events: a message start, a text block, and one text delta. No stop event.
const stream_prefix =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n";

/// A transport that streams a prefix, then parks until the gate opens. The run holds a live draft.
const StreamThenParkTransport = struct {
    prefix: []const u8,
    suffix: []const u8 = "", // The stream emits this after the gate opens, then ends.
    entered: *zio.ResetEvent,
    gate: *zio.ResetEvent,

    fn transportFor(self: *StreamThenParkTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: transport.Transport.VTable = .{ .open = open };
    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: transport.Request, info: *transport.AttemptInfo) anyerror!transport.ResponseBody {
        _ = info;
        _ = request;
        const self: *StreamThenParkTransport = @ptrCast(@alignCast(ctx));
        const reader = try arena.create(Reader);
        reader.* = .{ .prefix = self.prefix, .suffix = self.suffix, .entered = self.entered, .gate = self.gate };
        return .{ .ctx = reader, .vtable = &Reader.vtable };
    }
    const Reader = struct {
        prefix: []const u8,
        suffix: []const u8 = "",
        entered: *zio.ResetEvent,
        gate: *zio.ResetEvent,
        offset: usize = 0,
        parked: bool = false,
        const vtable: transport.ResponseBody.VTable = .{ .read = read, .deinit = deinitNoop };
        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *Reader = @ptrCast(@alignCast(ctx));
            if (self.offset < self.prefix.len) {
                const n = @min(buf.len, self.prefix.len - self.offset);
                @memcpy(buf[0..n], self.prefix[self.offset..][0..n]);
                self.offset += n;
                return n;
            }
            if (!self.parked) {
                self.entered.set(); // The prefix streamed. The run holds a live draft now.
                try self.gate.wait();
                self.parked = true;
            }
            const suffix_off = self.offset - self.prefix.len;
            if (suffix_off < self.suffix.len) {
                const n = @min(buf.len, self.suffix.len - suffix_off);
                @memcpy(buf[0..n], self.suffix[suffix_off..][0..n]);
                self.offset += n;
                return n;
            }
            return 0; // EOF ends the stream after the suffix, if any.
        }
        fn deinitNoop(_: *anyopaque) void {}
    };
};

/// Fold the daemon's published broadcasts into a fresh client. Assert it matches the daemon session.
fn conformAtPark(
    state: *State,
    sid: wire.ids.SessionId,
    entered: *zio.ResetEvent,
    gate: *zio.ResetEvent,
    log: *BroadcastLog,
    conn: *connection.Connection,
) !void {
    try entered.wait();
    try log.drain(conn);
    var client = domain_session.Session.init(std.testing.allocator, sid);
    defer client.deinit();
    for (log.events.items) |bc| try std.testing.expect(try client.applyBroadcast(bc) != .gap);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const rt = state.sessions.get(sid) orelse return error.NoRuntime;
    try std.testing.expect(try rt.session.eql(&client, scratch.allocator())); // no fold drift
    gate.set();
    try launchUntilIdle(state, sid);
}

/// Resync at the park and install the snapshot into a fresh client. Assert it rebuilds the live draft.
fn resyncInstallAtPark(state: *State, sid: wire.ids.SessionId, entered: *zio.ResetEvent, gate: *zio.ResetEvent) !void {
    try entered.wait();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try handlers.sessionResync(state, arena.allocator(), .{ .session_id = sid, .limit = null });
    var client = domain_session.Session.init(std.testing.allocator, sid);
    defer client.deinit();
    try client.installResync(result);
    const rt = state.sessions.get(sid) orelse return error.NoRuntime;
    // The snapshot rebuilds the streamed draft, the committed window, and the durable cursor.
    try std.testing.expect(client.active != null);
    try std.testing.expectEqual(rt.session.active.?.message_id, client.active.?.message_id);
    try std.testing.expectEqual(rt.session.active.?.run_id, client.active.?.run_id);
    try std.testing.expectEqual(@as(usize, 1), client.active.?.parts.items.len);
    try std.testing.expect(client.active.?.parts.items[0] == .text);
    try std.testing.expectEqualStrings("hello", client.active.?.parts.items[0].text.text.items);
    try std.testing.expectEqual(rt.session.base_seq, client.base_seq);
    try std.testing.expectEqual(rt.session.finalized_message_id, client.finalized_message_id);
    try std.testing.expectEqual(rt.session.committed.list.items.len, client.committed.list.items.len);
    gate.set();
    try launchUntilIdle(state, sid);
}

test "a resync snapshot reconstructs the live draft" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var transport_impl = StreamThenParkTransport{ .prefix = stream_prefix, .entered = &entered, .gate = &gate };
    fixture.state.route_transport = transport_impl.transportFor();

    const a = fixture.allocator();
    const sid = try createSession(&fixture, a, .{ .workspace_path = "/resync-live-draft", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var driver = try fixture.rt.spawn(resyncInstallAtPark, .{ &fixture.state, sid, &entered, &gate });
    try driver.join();
}

test "a client fold of the published stream matches the daemon session" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var log = BroadcastLog.init();
    defer log.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var transport_impl = StreamThenParkTransport{ .prefix = stream_prefix, .entered = &entered, .gate = &gate };
    fixture.state.route_transport = transport_impl.transportFor();

    const a = fixture.allocator();
    const sid = try createSession(&fixture, a, .{ .workspace_path = "/conform", .model = "mock/fast" });
    // Subscribe before the input starts the run, so the fold sees every frame from the first one.
    try fixture.register();
    try fixture.subscribe(sid);
    _ = try sendText(&fixture, a, sid, "hi");
    var driver = try fixture.rt.spawn(conformAtPark, .{ &fixture.state, sid, &entered, &gate, &log, fixture.conn });
    try driver.join();
}

/// This transport records the request and replays a fixed Anthropic reply.
const CaptureTransport = struct {
    gpa: std.mem.Allocator,
    reply: []const u8,
    url: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    api_key: std.ArrayList(u8) = .empty,

    fn deinit(self: *CaptureTransport) void {
        self.url.deinit(self.gpa);
        self.body.deinit(self.gpa);
        self.api_key.deinit(self.gpa);
    }

    fn transportFor(self: *CaptureTransport) transport.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: transport.Transport.VTable = .{ .open = open };

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: transport.Request, info: *transport.AttemptInfo) anyerror!transport.ResponseBody {
        _ = info;
        const self: *CaptureTransport = @ptrCast(@alignCast(ctx));
        try self.url.appendSlice(self.gpa, request.url);
        try self.body.appendSlice(self.gpa, request.body);
        for (request.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) try self.api_key.appendSlice(self.gpa, h.value);
        }
        const reader = try arena.create(Reader);
        reader.* = .{ .bytes = self.reply };
        return .{ .ctx = reader, .vtable = &Reader.vtable };
    }

    const Reader = struct {
        bytes: []const u8,
        offset: usize = 0,

        const vtable: transport.ResponseBody.VTable = .{ .read = read, .deinit = noop };

        fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
            const self: *Reader = @ptrCast(@alignCast(ctx));
            const remaining = self.bytes[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
        fn noop(_: *anyopaque) void {}
    };
};

test "a provider-qualified model builds the real endpoint, headers, and body" {
    var fixture = try TestState.initBare(null);
    defer fixture.deinit();
    const a = fixture.allocator();

    // State.deinit frees the loaded provider layer. Leave that layer for State.deinit.
    fixture.state.providers = try provider.config.loadBytes(std.testing.allocator,
        \\{"version":1,"providers":[{"id":"acme","base_url":"https://llm.acme.example/v1","protocol":"anthropic_messages",
        \\ "auth":{"api_key":{"header":"x_api_key","source":{"literal":"sk-test"}}},
        \\ "headers":[{"name":"anthropic-version","value":"2023-06-01"}],
        \\ "models":[{"id":"fast","upstream_id":"acme-fast-1","limits":{"context_window":200000,"max_output_tokens":8192}}]}]}
    );
    _ = try fixture.state.rebuildCatalog();
    var capture: CaptureTransport = .{ .gpa = std.testing.allocator, .reply = provider.transport.canned_reply };
    defer capture.deinit();
    fixture.state.route_transport = capture.transportFor();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/prov", .model = "acme/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();

    try std.testing.expectEqualStrings("https://llm.acme.example/v1/messages", capture.url.items);
    try std.testing.expectEqualStrings("sk-test", capture.api_key.items);
    // The body carries the exact upstream model rather than the session-qualified name.
    const sent = try std.json.parseFromSliceLeaky(std.json.Value, a, capture.body.items, .{});
    try std.testing.expectEqualStrings("acme-fast-1", sent.object.get("model").?.string);
    try std.testing.expect(std.mem.indexOf(u8, capture.body.items, "acme/fast") == null);
    // The committed assistant message records the resolved protocol and the session model.
    const history = (try database.message.historyPage(&fixture.state.db, a, sid.raw, 0, 10)).messages;
    try std.testing.expectEqual(wire.enums.ProviderProtocol.anthropic_messages, history[1].assistant.provenance.?.protocol);
    try std.testing.expectEqualStrings("acme/fast", history[1].assistant.provenance.?.model);
}

// A stream prefix that reaches the client. It opens a text block and sends one delta.
const started_text =
    "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n";

/// Run one turn against a scripted provider and return the session id.
fn runScripted(fixture: *TestState, a: std.mem.Allocator, name: []const u8, script: *provider.transport.ScriptedTransport) !wire.ids.SessionId {
    fixture.state.route_transport = script.transport();
    fixture.state.retry_policy = .{ .base_ms = 0, .cap_ms = 0 }; // No test waits for a real delay.
    const sid = try createSession(fixture, a, .{ .workspace_path = name, .model = "mock/fast" });
    _ = try sendText(fixture, a, sid, "hi");
    try launchUntilIdle(&fixture.state, sid);
    return sid;
}

/// Return the finish reason of the last committed assistant message.
fn lastFinish(state: *State, a: std.mem.Allocator, sid: wire.ids.SessionId) !wire.enums.StopReason {
    const history = (try database.message.historyPage(&state.db, a, sid.raw, 0, 10)).messages;
    return history[history.len - 1].assistant.finish.?;
}

test "a failed attempt repeats and the next attempt succeeds" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = [_]provider.transport.Step{
        .{ .open_error = error.ConnectionRefused },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    const sid = try runScripted(&fixture, a, "/retry-ok", &script);

    try std.testing.expectEqual(@as(usize, 2), script.opens); // the loop repeated the request
    try std.testing.expectEqual(wire.enums.StopReason.stop, try lastFinish(&fixture.state, a, sid));
}

test "output that reached the client stops a repeat" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // The client already folded this text. A repeat would show it twice.
    const steps = [_]provider.transport.Step{
        .{ .body_then_error = .{ .prefix = started_text, .err = error.ConnectionResetByPeer } },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    _ = try runScripted(&fixture, a, "/retry-semantic", &script);

    try std.testing.expectEqual(@as(usize, 1), script.opens);
}

test "a finished stream stops a repeat after a later read failure" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // The whole answer arrived. A repeat would ask for work the provider already did.
    const steps = [_]provider.transport.Step{
        .{ .body_then_error = .{ .prefix = final_text_reply, .err = error.ConnectionResetByPeer } },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    _ = try runScripted(&fixture, a, "/retry-done", &script);

    try std.testing.expectEqual(@as(usize, 1), script.opens);
}

test "a request that may already be held stops a repeat" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // No idempotency key exists for either provider, so a repeat could bill the same work twice.
    const steps = [_]provider.transport.Step{
        .{ .open_error = error.ConnectionResetByPeer },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps, .delivery = .possibly_sent };
    const sid = try runScripted(&fixture, a, "/retry-delivery", &script);

    try std.testing.expectEqual(@as(usize, 1), script.opens);
    try std.testing.expectEqual(wire.enums.StopReason.@"error", try lastFinish(&fixture.state, a, sid));
}

test "the attempt limit ends the run" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = [_]provider.transport.Step{
        .{ .open_error = error.ConnectionRefused },
        .{ .open_error = error.ConnectionRefused },
        .{ .open_error = error.ConnectionRefused },
        .{ .open_error = error.ConnectionRefused },
        .{ .open_error = error.ConnectionRefused },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    const sid = try runScripted(&fixture, a, "/retry-limit", &script);

    // Five attempts, then the run fails. The sixth step must stay unused.
    try std.testing.expectEqual(@as(usize, 5), script.opens);
    try std.testing.expectEqual(wire.enums.StopReason.@"error", try lastFinish(&fixture.state, a, sid));
}

/// Yield until the run records a waiting retry, then resync and report the activity state.
fn resyncDuringRetry(state: *State, sid: wire.ids.SessionId) !void {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        const rt = state.sessions.get(sid) orelse return error.NoRuntime;
        if (rt.active) |slot| if (slot.retry_state != null) break;
        try zio.yield();
    } else return error.NoRetryState;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try handlers.sessionResync(state, arena.allocator(), .{ .session_id = sid, .limit = null });
    // The stream already stopped, so a draft state would tell the client the model is still writing.
    try std.testing.expect(result.item.activity.state == .retrying);
    try std.testing.expectEqual(@as(u64, 1), result.item.activity.state.retrying.attempt);
    try std.testing.expectEqual(@as(u64, 5), result.item.activity.state.retrying.max_attempts);
    // A yield loop starves the timer, so wait for the delay before driving the run to idle.
    try zio.sleep(.fromMilliseconds(300));
    try launchUntilIdle(state, sid);
}

test "a resync during a retry delay reports the retry" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = [_]provider.transport.Step{
        .{ .open_error = error.ConnectionRefused },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = script.transport();
    // A real delay keeps the retry state observable while the driver resyncs.
    fixture.state.retry_policy = .{ .base_ms = 200, .cap_ms = 200 };

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/retry-activity", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");

    var driver = try fixture.rt.spawn(resyncDuringRetry, .{ &fixture.state, sid });
    try driver.join();
    try std.testing.expectEqual(@as(usize, 2), script.opens);
}

test "the retry budget covers the whole run, not one request" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    // Two rounds, each with one failure. One permit covers the first failure only.
    const steps = [_]provider.transport.Step{
        .{ .open_error = error.ConnectionRefused },
        .{ .body = one_tool_reply_a },
        .{ .open_error = error.ConnectionRefused },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.retry_budget = 1;
    var host: EchoHost = .{};
    fixture.state.tool_host = host.host();
    const sid = try runScripted(&fixture, a, "/retry-budget", &script);

    // Attempt 1 fails and spends the only permit. Round 2 fails and stops, so step 4 stays unused.
    try std.testing.expectEqual(@as(usize, 3), script.opens);
    try std.testing.expectEqual(wire.enums.StopReason.@"error", try lastFinish(&fixture.state, a, sid));
}

/// A tool host that answers every read with fixed bytes, so a tool round can reach its next request.
const EchoHost = struct {
    const vtable: tools.ToolHost.VTable = blk: {
        var v = test_host.unsupported;
        v.readRange = readRange;
        break :blk v;
    };

    fn host(self: *EchoHost) tools.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn readRange(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, range: tools.Range, limits: tools.ReadLimits) tools.HostError!tools.RangeRead {
        _ = .{ ctx, path, range, limits };
        return .{ .text = try scratch.dupe(u8, "x\n") };
    }
};

/// Cancel the run while it waits for its next attempt.
fn cancelDuringRetryDelay(state: *State, sid: wire.ids.SessionId, run_id: u64) !void {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        const rt = state.sessions.get(sid) orelse return error.NoRuntime;
        if (rt.active) |slot| if (slot.retry_state != null) break;
        try zio.yield();
    } else return error.NoRetryState;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try handlers.sessionCancelRun(state, arena.allocator(), .{ .session_id = sid, .run_id = run_id });
    try launchUntilIdle(state, sid);
}

test "a cancel during a retry delay stops before the next attempt" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const steps = [_]provider.transport.Step{
        .{ .open_error = error.ConnectionRefused },
        .{ .body = final_text_reply },
    };
    var script: provider.transport.ScriptedTransport = .{ .steps = &steps };
    fixture.state.route_transport = script.transport();
    // A long delay proves the cancel interrupts the wait instead of outliving it.
    fixture.state.retry_policy = .{ .base_ms = 30_000, .cap_ms = 30_000 };

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/retry-cancel", .model = "mock/fast" });
    const started = (try sendText(&fixture, a, sid, "hi")).started;

    var driver = try fixture.rt.spawn(cancelDuringRetryDelay, .{ &fixture.state, sid, started.run_id });
    try driver.join(); // A cancel that did not interrupt the sleep would hold this for 30 seconds.

    try std.testing.expectEqual(@as(usize, 1), script.opens); // the second attempt never opened
    try std.testing.expectEqual(wire.enums.StopReason.canceled, try lastFinish(&fixture.state, a, sid));
}

fn cloud_catalog_test_local() !provider.config.Loaded {
    return provider.config.loadBytes(std.testing.allocator,
        \\{"version":1,"providers":[{"id":"anthropic","base_url":"https://api.anthropic.com/v1",
        \\ "protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"literal":"k"}}}}]}
    );
}

test "catalog.list serves an empty catalog before the first sync" {
    var fixture = try TestState.initBare(null);
    defer fixture.deinit();
    const a = fixture.allocator();

    const result = try handlers.catalogList(&fixture.state, a, .{});
    try std.testing.expect(result == .full);
    try std.testing.expectEqual(@as(usize, 0), result.full.models.len);
    try std.testing.expectEqual(@as(usize, 0), result.full.providers.len);
    // A zero revision says the daemon holds no catalog yet.
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &result.full.catalog_rev.raw);
}

test "catalog.refresh dispatches the cloud refresh" {
    var fixture = try TestState.initBare("not a url");
    defer fixture.deinit();

    var buffer: [1024]u8 = undefined;
    const framed = try call(&fixture,
        \\{"id":"refresh-1","method":"catalog.refresh","params":{}}
    , &buffer);
    const payload = try responsePayload(framed);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"code\":-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "not implemented") == null);
}

test "a local provider changes the catalog before the first cloud sync" {
    var fixture = try TestState.initBare(null);
    defer fixture.deinit();
    const a = fixture.allocator();

    fixture.state.providers = try cloud_catalog_test_local();
    try std.testing.expect(try fixture.state.rebuildCatalog());

    const initialized = try handlers.initialize(&fixture.state, a);
    try std.testing.expect(!std.mem.eql(u8, &initialized.catalog_rev.raw, &@as([64]u8, @splat(0))));

    const full = try handlers.catalogList(&fixture.state, a, .{ .since_rev = .bytes(@splat(0)) });
    try std.testing.expect(full == .full);
    try std.testing.expectEqual(@as(usize, 1), full.full.providers.len);
    try std.testing.expectEqualSlices(u8, &initialized.catalog_rev.raw, &full.full.catalog_rev.raw);

    const unchanged = try handlers.catalogList(&fixture.state, a, .{ .since_rev = full.full.catalog_rev });
    try std.testing.expect(unchanged == .unchanged);
    try std.testing.expect(!try fixture.state.rebuildCatalog());
}

test "catalog.list projects stored models and honors a matching revision" {
    var fixture = try TestState.initBare(null);
    defer fixture.deinit();
    const a = fixture.allocator();

    // The revision must be a sha-512 hex digest, so substitute it into the document.
    const rev_hex = "0123456789abcdef" ** 8;
    const raw_doc = try std.mem.replaceOwned(u8, a,
        \\{"version":1,"catalog_rev":"REV","providers":[
        \\{"id":"anthropic","name":"Anthropic","base_url":"https://api.anthropic.com/v1",
        \\ "protocol":"anthropic_messages","auth":{"kind":"api_key","header":"x_api_key"},
        \\ "cache":"ephemeral","headers":[],"models":[{"id":"m","upstream_id":"u","name":"M",
        \\ "limits":{"context_window":200000,"max_output_tokens":null},
        \\ "cost":{"input":3.0,"output":15.0,"cache_read":null,"cache_write":null},
        \\ "flags":{"supports_tools":true,"supports_vision":false},"reasoning":true,
        \\ "reasoning_levels":[null,"low","medium"],"status":null}]}]}
    , "REV", rev_hex);
    const parsed = try cloud_catalog.decode(a, raw_doc);
    try catalog_store.replace(&fixture.state.db, a, parsed.providers, parsed.catalog_rev, "etag-1");

    // A catalog row alone is not offered; a local key makes it a configured provider.
    fixture.state.providers = try cloud_catalog_test_local(); // State.deinit frees this.
    _ = try fixture.state.rebuildCatalog();
    const result = try handlers.catalogList(&fixture.state, a, .{});
    try std.testing.expect(result == .full);
    try std.testing.expectEqual(@as(usize, 1), result.full.providers.len);
    try std.testing.expectEqual(wire.enums.ProviderSource.local, result.full.providers[0].source);
    try std.testing.expectEqual(@as(usize, 1), result.full.models.len);

    const m = result.full.models[0];
    try std.testing.expectEqualStrings("m", m.id);
    try std.testing.expectEqualStrings("anthropic", m.provider);
    try std.testing.expectEqual(@as(?u64, 200000), m.context_window);
    try std.testing.expect(m.max_output_tokens == null);
    try std.testing.expect(m.cost.cache_write == null);
    try std.testing.expectEqual(@as(usize, 2), m.reasoning_levels.len); // The null level is gone.
    try std.testing.expectEqualStrings("medium", m.default_reasoning);

    // A client that already holds this revision gets no catalog data.
    const again = try handlers.catalogList(&fixture.state, a, .{ .since_rev = result.full.catalog_rev });
    try std.testing.expect(again == .unchanged);

    // A stale revision returns the whole catalog again.
    const stale = try handlers.catalogList(&fixture.state, a, .{ .since_rev = .bytes(@splat(0)) });
    try std.testing.expect(stale == .full);
}

/// Insert a related session directly. `session.create` makes roots, and no method builds these yet.
/// A child records the parent transcript anchor. A fork records only its source.
fn createRelated(
    state: *State,
    a: std.mem.Allocator,
    relative: wire.ids.SessionId,
    origin: enum { child, fork },
) !wire.ids.SessionId {
    const snap = (try database.session.snapshot(&state.db, a, relative.raw)) orelse return error.UnknownSession;
    const now = state.nowMillis();
    var params: database.session.CreateParams = .{
        .id = state.newId(),
        .workspace_id = snap.workspace_id,
        .origin = @tagName(origin),
        .profile = "default",
        .model = "mock/fast",
        .reasoning = "",
        .config_rev = 0,
        .permission = "normal",
        .title = @tagName(origin),
        .created_at_ms = now,
        .updated_at_ms = now,
    };
    switch (origin) {
        .child => {
            params.parent_id = relative.raw;
            params.parent_message_id = 1;
            params.parent_part_id = 0;
        },
        .fork => params.source_id = relative.raw,
    }
    var tx = try state.db.begin();
    defer tx.deinit();
    try database.session.create(&state.db, params);
    // A run resolves its config by revision, so seed revision 0 exactly as session.create does.
    try database.config.recordInitial(&state.db, params.id, params.model, params.reasoning);
    try tx.commit();
    return .bytes(params.id);
}

fn countRowsFor(db: *database.Database, table: []const u8, sid: wire.ids.SessionId) !i64 {
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, "SELECT count(*) FROM {s} WHERE session_id = ?1", .{table});
    // zqlite binds a plain byte slice as TEXT, and SQLite never matches TEXT against a BLOB column.
    const row = (try db.conn.row(text, .{zqlite.blob(&sid.raw)})) orelse return error.NoRow;
    defer row.deinit();
    return row.int(0);
}

test "session.remove deletes the session and cascades its transcript" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{
        .workspace_path = "/remove",
        .model = "mock/fast",
        .system_prompt = "be brief",
    });
    _ = try sendText(&fixture, a, sid, "hi");
    var launch = try fixture.rt.spawn(launchUntilIdle, .{ &fixture.state, sid });
    try launch.join();
    // Queue one durable input behind the settled turn, so the delete also cascades that table.
    {
        const content = [_]wire.content.ContentPart{.{ .text = .{ .text = "later" } }};
        const now = fixture.state.nowMillis();
        var tx = try fixture.state.db.begin();
        defer tx.deinit();
        _ = try database.input.enqueue(&fixture.state.db, a, sid.raw, fixture.state.newId(), now, &content, now);
        try tx.commit();
    }

    // Every child table must hold a row, so the delete exercises each cascade.
    const tables = [_][]const u8{ "events", "messages", "session_configs", "session_prompts", "pending_inputs" };
    for (tables) |table| try std.testing.expect((try countRowsFor(&fixture.state.db, table, sid)) > 0);

    _ = try handlers.sessionRemove(&fixture.state, a, .{ .session_id = sid });

    try std.testing.expectEqual(@as(u64, 0), try database.session.count(&fixture.state.db, a, .{}));
    for (tables) |table| try std.testing.expectEqual(@as(i64, 0), try countRowsFor(&fixture.state.db, table, sid));
    try std.testing.expect(fixture.state.sessions.get(sid) == null);
}

test "session.remove announces the removal with the next index revision" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var log = BroadcastLog.init();
    defer log.deinit();
    const a = fixture.allocator();

    try fixture.register();
    const sid = try createSession(&fixture, a, .{ .workspace_path = "/announce-remove" });
    const before = fixture.state.session_revision;
    _ = try handlers.sessionRemove(&fixture.state, a, .{ .session_id = sid });
    try log.drain(fixture.conn);

    var removed: usize = 0;
    for (log.events.items) |bc| switch (bc) {
        .session_removed_data => |d| {
            removed += 1;
            try std.testing.expectEqual(sid, d.session_id);
            try std.testing.expectEqual(before + 1, d.revision);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(before + 1, fixture.state.session_revision);
}

test "session.remove rejects a session that has children" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const parent = try createSession(&fixture, a, .{ .workspace_path = "/tree" });
    _ = try createRelated(&fixture.state, a, parent, .child);

    try std.testing.expectError(
        error.SessionHasChildren,
        handlers.sessionRemove(&fixture.state, a, .{ .session_id = parent }),
    );
    try std.testing.expectEqual(@as(u64, 2), try database.session.count(&fixture.state.db, a, .{}));
}

test "cascade_children removes the subtree and keeps a fork of it" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    const a = fixture.allocator();

    const parent = try createSession(&fixture, a, .{ .workspace_path = "/tree" });
    const child = try createRelated(&fixture.state, a, parent, .child);
    const grandchild = try createRelated(&fixture.state, a, child, .child);
    const forked = try createRelated(&fixture.state, a, parent, .fork);

    _ = try handlers.sessionRemove(&fixture.state, a, .{ .session_id = parent, .cascade_children = true });

    // A fork owns its transcript, so it survives with a source_id that now resolves to nothing.
    try std.testing.expectEqual(@as(u64, 1), try database.session.count(&fixture.state.db, a, .{}));
    try std.testing.expect(try database.session.exists(&fixture.state.db, a, forked.raw));
    for ([_]wire.ids.SessionId{ parent, child, grandchild }) |id| {
        try std.testing.expect(!try database.session.exists(&fixture.state.db, a, id.raw));
    }
}

/// Remove the session while its provider read parks, then release the read.
fn removeWhileBlocked(
    state: *State,
    sid: wire.ids.SessionId,
    entered: *zio.ResetEvent,
    gate: *zio.ResetEvent,
) !void {
    try entered.wait(); // The read parked, so the run is active.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.SessionBusy,
        handlers.sessionRemove(state, arena.allocator(), .{ .session_id = sid }),
    );
    gate.set();
    try launchUntilIdle(state, sid);
}

test "session.remove rejects a session with an active run" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var interrupted = false;
    var blocking: BlockingTransport = .{ .entered = &entered, .gate = &gate, .interrupted = &interrupted };
    fixture.state.route_transport = blocking.transportFor();
    const a = fixture.allocator();

    const sid = try createSession(&fixture, a, .{ .workspace_path = "/busy", .model = "mock/fast" });
    _ = try sendText(&fixture, a, sid, "hi");
    var driver = try fixture.rt.spawn(removeWhileBlocked, .{ &fixture.state, sid, &entered, &gate });
    try driver.join();

    // The reject left the session whole, so it removes cleanly once the run settles.
    try std.testing.expectEqual(@as(u64, 1), try database.session.count(&fixture.state.db, a, .{}));
    _ = try handlers.sessionRemove(&fixture.state, a, .{ .session_id = sid });
    try std.testing.expectEqual(@as(u64, 0), try database.session.count(&fixture.state.db, a, .{}));
}

test "session.remove dispatch maps an unknown session to its error code" {
    var fixture = try TestState.init();
    defer fixture.deinit();

    var buffer: [1024]u8 = undefined;
    const frame =
        \\{"id":"9","method":"session.remove","params":{"session_id":"00000000000000000000000000000000"}}
    ;
    const written = try call(&fixture, frame, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":-31000") != null);
}

/// Remove the root while a child run parks. The busy child must block the whole cascade.
fn removeWhileChildBlocked(
    state: *State,
    root: wire.ids.SessionId,
    child: wire.ids.SessionId,
    entered: *zio.ResetEvent,
    gate: *zio.ResetEvent,
) !void {
    try entered.wait(); // The child read parked, so the child run is active.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.SessionBusy,
        handlers.sessionRemove(state, arena.allocator(), .{ .session_id = root, .cascade_children = true }),
    );
    gate.set();
    try launchUntilIdle(state, child);
}

test "a busy child blocks the cascade and leaves the whole tree" {
    var fixture = try TestState.init();
    defer fixture.deinit();
    var entered: zio.ResetEvent = .init;
    var gate: zio.ResetEvent = .init;
    var interrupted = false;
    var blocking: BlockingTransport = .{ .entered = &entered, .gate = &gate, .interrupted = &interrupted };
    fixture.state.route_transport = blocking.transportFor();
    const a = fixture.allocator();

    const root = try createSession(&fixture, a, .{ .workspace_path = "/busy-tree", .model = "mock/fast" });
    const child = try createRelated(&fixture.state, a, root, .child);
    _ = try sendText(&fixture, a, child, "hi");
    var driver = try fixture.rt.spawn(removeWhileChildBlocked, .{ &fixture.state, root, child, &entered, &gate });
    try driver.join();

    // The reject came before the first delete, so neither the root nor the child lost a row.
    try std.testing.expectEqual(@as(u64, 2), try database.session.count(&fixture.state.db, a, .{}));
    _ = try handlers.sessionRemove(&fixture.state, a, .{ .session_id = root, .cascade_children = true });
    try std.testing.expectEqual(@as(u64, 0), try database.session.count(&fixture.state.db, a, .{}));
}
