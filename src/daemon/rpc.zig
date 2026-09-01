//! Decode a wire request, dispatch it, and write its response frame.

const std = @import("std");
const wire = @import("wire");
const wss = @import("websocket").server;
const State = @import("State.zig");
const handlers = @import("handlers.zig");
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
            // The fetch runs on the scheduler, so this answers now and `catalog.changed` reports the result.
            state.requestCatalogRefresh();
            const result: wire.catalog.CatalogRefreshResult = .{ .catalog_rev = state.store.merged.revision };
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
        .@"fs.stat" => {
            const result = handlers.fsStat(state, arena, request.params.fs_stat_params) catch |err| switch (err) {
                error.BadPath => return errorResponse(request.id, .bad_request, "the daemon cannot read the path"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .fs_stat_result = result } } };
        },
        .@"fs.browse" => {
            const result = handlers.fsBrowse(state, arena, request.params.fs_browse_params) catch |err| switch (err) {
                error.BadPath => return errorResponse(request.id, .bad_request, "the daemon cannot list the path"),
                error.BadRequest => return errorResponse(request.id, .bad_request, "the browse limit is out of range"),
                error.BadCursor => return errorResponse(request.id, .stale_cursor, "stale cursor"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .fs_browse_result = result } } };
        },
        .@"auth.list" => {
            const result = try handlers.authList(state, arena, request.params.empty);
            return .{ .ok = .{ .id = request.id, .result = .{ .auth_list_result = result } } };
        },
        .@"auth.set_api_key" => {
            const result = handlers.authSetApiKey(state, arena, request.params.auth_set_api_key_params) catch |err| switch (err) {
                error.BadProviderId => return errorResponse(request.id, .bad_request, "the provider id is not a selector part"),
                error.BadApiKey => return errorResponse(request.id, .bad_request, "the api key is empty"),
                error.NoConfigDirectory => return errorResponse(request.id, .internal, "no config directory holds providers.json"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .empty = result } } };
        },
        .@"auth.remove" => {
            const result = handlers.authRemove(state, arena, request.params.auth_remove_params) catch |err| switch (err) {
                error.BadProviderId => return errorResponse(request.id, .bad_request, "the provider id is not a selector part"),
                error.UnknownProvider => return errorResponse(request.id, .unknown_provider, "unknown provider"),
                error.NoConfigDirectory => return errorResponse(request.id, .internal, "no config directory holds providers.json"),
                else => return err,
            };
            return .{ .ok = .{ .id = request.id, .result = .{ .empty = result } } };
        },
        inline else => |method| {
            comptime assertUnimplemented(method);
            return errorResponse(request.id, .not_implemented, "not implemented");
        },
    }
}

/// The methods the daemon does not implement yet. A dispatch arm always wins over this list.
const unimplemented = [_]wire.enums.MethodName{
    .@"session.patch",
    .@"session.fork",
    .@"session.compact",
    .@"session.rewind",
    .@"permission.decide",
    .@"permission.rules",
    .@"permission.forget",
    .@"auth.login",
    .@"auth.cancel_login",
    .@"workspace.remove",
    .@"workspace.skills",
};

/// Stop the build when a new method reaches the fallback arm and the list above does not name it.
fn assertUnimplemented(comptime method: wire.enums.MethodName) void {
    for (unimplemented) |m| if (m == method) return;
    @compileError("`" ++ @tagName(method) ++ "` has no dispatch arm; add one or list it as unimplemented");
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

test {
    _ = @import("rpc_test.zig");
}
