//! RPC request, response, and notification envelopes.

const std = @import("std");
const auth = @import("auth.zig");
const catalog = @import("catalog.zig");
const enums = @import("enums.zig");
const ids = @import("ids.zig");
const initialize = @import("initialize.zig");
const input = @import("input.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const permission = @import("permission.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const subscription = @import("subscription.zig");
const tool = @import("tool.zig");
const fs = @import("fs.zig");
const workspace = @import("workspace.zig");

fn stringifyPayload(self: anytype, jw: *std.json.Stringify) !void {
    switch (self) {
        inline else => |payload| try jw.write(payload),
    }
}

/// This union carries client request parameters.
pub const RequestParams = union(enum) {
    initialize_params: initialize.InitializeParams,
    session_list_params: session.SessionListParams,
    create_session: misc.CreateSession,
    session_patch_params: session.SessionPatchParams,
    session_remove_params: session.SessionRemoveParams,
    session_fork_params: session.SessionForkParams,
    session_compact_params: session.SessionCompactParams,
    session_rewind_params: session.SessionRewindParams,
    session_send_input_params: session.SessionSendInputParams,
    session_cancel_input_params: session.SessionCancelInputParams,
    session_cancel_run_params: session.SessionCancelRunParams,
    session_resync_params: session.SessionResyncParams,
    session_history_params: session.SessionHistoryParams,
    permission_decide_params: permission.PermissionDecideParams,
    session_config_params: session.SessionConfigParams,
    subscription_set_params: subscription.SubscriptionSetParams,
    catalog_list_params: catalog.CatalogListParams,
    empty: misc.Empty,
    auth_set_api_key_params: auth.AuthSetApiKeyParams,
    auth_login_params: auth.AuthLoginParams,
    auth_cancel_login_params: auth.AuthCancelLoginParams,
    auth_remove_params: auth.AuthRemoveParams,
    fs_stat_params: fs.FsStatParams,
    fs_browse_params: fs.FsBrowseParams,
    workspace_ref: workspace.WorkspaceRef,
    permission_forget_params: permission.PermissionForgetParams,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try stringifyPayload(self, jw);
    }
};

/// This union carries server response results.
pub const ResponseResult = union(enum) {
    initialize_result: misc.InitializeResult,
    session_list_result: session.SessionListResult,
    session_result: session.SessionResult,
    empty: misc.Empty,
    session_compact_result: session.SessionCompactResult,
    session_send_input_result: session.SessionSendInputResult,
    session_cancel_input_result: session.SessionCancelInputResult,
    session_cancel_run_result: session.SessionCancelRunResult,
    session_resync_result: session.SessionResyncResult,
    session_history_result: session.SessionHistoryResult,
    session_config_result: session.SessionConfigResult,
    catalog_list_result: catalog.CatalogListResult,
    catalog_refresh_result: catalog.CatalogRefreshResult,
    auth_list_result: auth.AuthListResult,
    auth_login_result: auth.AuthLoginResult,
    fs_stat_result: fs.FsStatResult,
    fs_browse_result: fs.FsBrowseResult,
    workspace_remove_result: workspace.WorkspaceRemoveResult,
    workspace_skills_result: workspace.WorkspaceSkillsResult,
    permission_rules_result: permission.PermissionRulesResult,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try stringifyPayload(self, jw);
    }
};

/// This union carries server broadcast data.
pub const BroadcastData = union(enum) {
    session_summary_changed_data: session.SessionSummaryChangedData,
    session_activity_changed_data: session.SessionActivityChangedData,
    session_removed_data: session.SessionRemovedData,
    workspace_created_data: workspace.WorkspaceCreatedData,
    workspace_removed_data: workspace.WorkspaceRemovedData,
    permission_rules_changed_data: permission.PermissionRulesChangedData,
    catalog_changed_data: catalog.CatalogChangedData,
    auth_login_finished_data: auth.AuthLoginFinishedData,
    auth_changed_data: auth.AuthChangedData,
    notice: misc.Notice,
    message_committed_data: message.MessageCommittedData,
    run_started_data: run.RunStartedData,
    run_done_data: run.RunDoneData,
    config_changed_data: misc.ConfigChangedData,
    transcript_truncated_data: misc.TranscriptTruncatedData,
    message_started_data: message.MessageStartedData,
    message_discarded_data: message.MessageDiscardedData,
    message_part_added_data: message.MessagePartAddedData,
    message_part_delta_data: message.MessagePartDeltaData,
    message_part_finalized_data: message.MessagePartFinalizedData,
    tool_state_changed_data: tool.ToolStateChangedData,
    tool_output_delta_data: message.ToolOutputDeltaData,
    input_queued_data: input.InputQueuedData,
    input_canceled_data: input.InputCanceledData,
    session_deltas_shed_data: session.SessionDeltasShedData,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try stringifyPayload(self, jw);
    }
};

/// Maps an RPC method to its parameter and result types.
pub const MethodSpec = struct {
    name: enums.MethodName,
    params: type,
    result: type,
    params_optional: bool,
};

/// This table maps each RPC method to its wire types.
pub const methods = [_]MethodSpec{
    .{ .name = .initialize, .params = initialize.InitializeParams, .result = misc.InitializeResult, .params_optional = false },
    .{ .name = .@"session.list", .params = session.SessionListParams, .result = session.SessionListResult, .params_optional = true },
    .{ .name = .@"session.create", .params = misc.CreateSession, .result = session.SessionResult, .params_optional = true },
    .{ .name = .@"session.patch", .params = session.SessionPatchParams, .result = session.SessionResult, .params_optional = false },
    .{ .name = .@"session.remove", .params = session.SessionRemoveParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"session.fork", .params = session.SessionForkParams, .result = session.SessionResult, .params_optional = false },
    .{ .name = .@"session.compact", .params = session.SessionCompactParams, .result = session.SessionCompactResult, .params_optional = false },
    .{ .name = .@"session.rewind", .params = session.SessionRewindParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"session.send_input", .params = session.SessionSendInputParams, .result = session.SessionSendInputResult, .params_optional = false },
    .{ .name = .@"session.cancel_input", .params = session.SessionCancelInputParams, .result = session.SessionCancelInputResult, .params_optional = false },
    .{ .name = .@"session.cancel_run", .params = session.SessionCancelRunParams, .result = session.SessionCancelRunResult, .params_optional = false },
    .{ .name = .@"session.resync", .params = session.SessionResyncParams, .result = session.SessionResyncResult, .params_optional = false },
    .{ .name = .@"session.history", .params = session.SessionHistoryParams, .result = session.SessionHistoryResult, .params_optional = false },
    .{ .name = .@"permission.decide", .params = permission.PermissionDecideParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"session.config", .params = session.SessionConfigParams, .result = session.SessionConfigResult, .params_optional = false },
    .{ .name = .@"subscription.set", .params = subscription.SubscriptionSetParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"catalog.list", .params = catalog.CatalogListParams, .result = catalog.CatalogListResult, .params_optional = true },
    .{ .name = .@"catalog.refresh", .params = misc.Empty, .result = catalog.CatalogRefreshResult, .params_optional = true },
    .{ .name = .@"auth.list", .params = misc.Empty, .result = auth.AuthListResult, .params_optional = true },
    .{ .name = .@"auth.set_api_key", .params = auth.AuthSetApiKeyParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"auth.login", .params = auth.AuthLoginParams, .result = auth.AuthLoginResult, .params_optional = false },
    .{ .name = .@"auth.cancel_login", .params = auth.AuthCancelLoginParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"auth.remove", .params = auth.AuthRemoveParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"fs.stat", .params = fs.FsStatParams, .result = fs.FsStatResult, .params_optional = false },
    .{ .name = .@"fs.browse", .params = fs.FsBrowseParams, .result = fs.FsBrowseResult, .params_optional = true },
    .{ .name = .@"workspace.remove", .params = workspace.WorkspaceRef, .result = workspace.WorkspaceRemoveResult, .params_optional = false },
    .{ .name = .@"workspace.skills", .params = workspace.WorkspaceRef, .result = workspace.WorkspaceSkillsResult, .params_optional = false },
    .{ .name = .@"permission.rules", .params = workspace.WorkspaceRef, .result = permission.PermissionRulesResult, .params_optional = false },
    .{ .name = .@"permission.forget", .params = permission.PermissionForgetParams, .result = misc.Empty, .params_optional = false },
};

/// Maps a broadcast name to its data type.
pub const BroadcastSpec = struct {
    name: enums.BroadcastName,
    data: type,
};

/// This table maps each broadcast name to its wire type.
pub const broadcasts = [_]BroadcastSpec{
    .{ .name = .@"session.summary_changed", .data = session.SessionSummaryChangedData },
    .{ .name = .@"session.activity_changed", .data = session.SessionActivityChangedData },
    .{ .name = .@"session.removed", .data = session.SessionRemovedData },
    .{ .name = .@"workspace.created", .data = workspace.WorkspaceCreatedData },
    .{ .name = .@"workspace.removed", .data = workspace.WorkspaceRemovedData },
    .{ .name = .@"permission.rules_changed", .data = permission.PermissionRulesChangedData },
    .{ .name = .@"catalog.changed", .data = catalog.CatalogChangedData },
    .{ .name = .@"auth.login_finished", .data = auth.AuthLoginFinishedData },
    .{ .name = .@"auth.changed", .data = auth.AuthChangedData },
    .{ .name = .notice, .data = misc.Notice },
    .{ .name = .@"message.committed", .data = message.MessageCommittedData },
    .{ .name = .@"run.started", .data = run.RunStartedData },
    .{ .name = .@"run.done", .data = run.RunDoneData },
    .{ .name = .@"config.changed", .data = misc.ConfigChangedData },
    .{ .name = .@"transcript.truncated", .data = misc.TranscriptTruncatedData },
    .{ .name = .@"message.started", .data = message.MessageStartedData },
    .{ .name = .@"message.discarded", .data = message.MessageDiscardedData },
    .{ .name = .@"message.part_added", .data = message.MessagePartAddedData },
    .{ .name = .@"message.part_delta", .data = message.MessagePartDeltaData },
    .{ .name = .@"message.part_finalized", .data = message.MessagePartFinalizedData },
    .{ .name = .@"tool.state_changed", .data = tool.ToolStateChangedData },
    .{ .name = .@"tool.output_delta", .data = message.ToolOutputDeltaData },
    .{ .name = .@"input.queued", .data = input.InputQueuedData },
    .{ .name = .@"input.canceled", .data = input.InputCanceledData },
    .{ .name = .@"session.deltas_shed", .data = session.SessionDeltasShedData },
};

fn decodeFromTable(
    a: std.mem.Allocator,
    method: anytype,
    v: std.json.Value,
    optional_v: std.json.Value,
    o: std.json.ParseOptions,
    comptime table: anytype,
    comptime Target: type,
    comptime payload_field: []const u8,
) !Target {
    inline for (table) |spec| {
        if (method == spec.name) {
            const value = if (@hasField(@TypeOf(spec), "params_optional"))
                if (spec.params_optional) optional_v else v
            else
                v;
            const payload = @field(spec, payload_field);
            inline for (@typeInfo(Target).@"union".fields) |field| {
                if (field.type == payload)
                    return @unionInit(Target, field.name, try std.json.parseFromValueLeaky(payload, a, value, o));
            }
            return error.InvalidEnumTag;
        }
    }
    return error.InvalidEnumTag;
}

/// This union carries an RPC response.
pub const Response = union(enum) {
    ok: ResponseOk,
    err: ResponseError,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try stringifyPayload(self, jw);
    }
};

/// This type carries an RPC request.
pub const Request = struct {
    id: ids.RequestId,
    method: enums.MethodName,
    params: RequestParams,

    /// Decode a tagged wire union from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        const v = try std.json.Value.jsonParse(a, s, o);
        return jsonParseFromValue(a, v, o);
    }

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        const obj = switch (v) {
            .object => |obj| obj,
            else => return error.UnexpectedToken,
        };
        const id_value = obj.get("id") orelse return error.MissingField;
        const id = switch (id_value) {
            .string => |id| id,
            else => return error.UnexpectedToken,
        };
        const method_value = obj.get("method") orelse return error.MissingField;
        const method_string = switch (method_value) {
            .string => |method| method,
            else => return error.UnexpectedToken,
        };
        const method = std.meta.stringToEnum(enums.MethodName, method_string) orelse return error.InvalidEnumTag;
        const pv = obj.get("params") orelse std.json.Value{ .object = .empty };
        const optional_pv = switch (pv) {
            .null => std.json.Value{ .object = .empty },
            else => pv,
        };
        var arm_opts = o;
        arm_opts.ignore_unknown_fields = true;

        const params = try decodeFromTable(a, method, pv, optional_pv, arm_opts, methods, RequestParams, "params");

        return .{ .id = id, .method = method, .params = params };
    }

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("method");
        try jw.write(@tagName(self.method));
        try jw.objectField("params");
        try jw.write(self.params);
        try jw.endObject();
    }
};

/// This type carries a successful RPC response.
pub const ResponseOk = struct {
    id: ids.RequestId,
    result: ResponseResult,
};

/// This type carries a failed RPC response.
pub const ResponseError = struct {
    id: ids.RequestId,
    @"error": misc.ErrorObject,
};

/// This type carries an RPC notification.
pub const Notification = struct {
    method: enums.BroadcastName,
    params: BroadcastData,

    /// Decode a tagged wire union from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        const v = try std.json.Value.jsonParse(a, s, o);
        return jsonParseFromValue(a, v, o);
    }

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        const obj = switch (v) {
            .object => |obj| obj,
            else => return error.UnexpectedToken,
        };
        const method_value = obj.get("method") orelse return error.MissingField;
        const method_string = switch (method_value) {
            .string => |method| method,
            else => return error.UnexpectedToken,
        };
        const method = std.meta.stringToEnum(enums.BroadcastName, method_string) orelse return error.InvalidEnumTag;
        const pv = obj.get("params") orelse return error.MissingField;
        var arm_opts = o;
        arm_opts.ignore_unknown_fields = true;

        const params = try decodeFromTable(a, method, pv, pv, arm_opts, broadcasts, BroadcastData, "data");

        return .{ .method = method, .params = params };
    }

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("method");
        try jw.write(@tagName(self.method));
        try jw.objectField("params");
        try jw.write(self.params);
        try jw.endObject();
    }
};

/// Decode a method result from its JSON value.
pub fn resultFromValue(a: std.mem.Allocator, method: enums.MethodName, v: std.json.Value, o: std.json.ParseOptions) !ResponseResult {
    var arm_opts = o;
    arm_opts.ignore_unknown_fields = true;
    return decodeFromTable(a, method, v, v, arm_opts, methods, ResponseResult, "result");
}

/// Decode a method response from its JSON value.
pub fn responseFromValue(a: std.mem.Allocator, method: enums.MethodName, v: std.json.Value, o: std.json.ParseOptions) !Response {
    const obj = switch (v) {
        .object => |obj| obj,
        else => return error.UnexpectedToken,
    };
    var arm_opts = o;
    arm_opts.ignore_unknown_fields = true;
    if (obj.get("error") != null)
        return .{ .err = try std.json.parseFromValueLeaky(ResponseError, a, v, arm_opts) };

    const id_value = obj.get("id") orelse return error.MissingField;
    const id = switch (id_value) {
        .string => |id| id,
        else => return error.UnexpectedToken,
    };
    const result = obj.get("result") orelse return error.MissingField;
    return .{ .ok = .{ .id = id, .result = try resultFromValue(a, method, result, o) } };
}

const testing = std.testing;
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "request envelope round-trips" {
    const json =
        \\{"id":"req-1","method":"initialize","params":{"client":{"name":"test","version":"1"}}}
    ;
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json, parse_opts);
    defer parsed.deinit();
    try testing.expectEqualStrings("req-1", parsed.value.id);
    try testing.expect(parsed.value.params == .initialize_params);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(
        \\{"id":"req-1","method":"initialize","params":{"protocol":1,"client":{"name":"test","version":"1"}}}
    , buf.written());
}

test "notification envelope round-trips" {
    const json =
        \\{"method":"notice","params":{"level":"info","source":"test","message":"hello"}}
    ;
    const parsed = try std.json.parseFromSlice(Notification, testing.allocator, json, parse_opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.params == .notice);
    try testing.expectEqualStrings("hello", parsed.value.params.notice.message);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "result dispatch and response error" {
    const result_json =
        \\{"protocol":1,"daemon":{"version":"v","server_now_ms":1},"workspaces":[],"profiles":[],"agents":[],"session_revision":1,"catalog_rev":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","capabilities":[]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result_value = try std.json.parseFromSlice(std.json.Value, arena.allocator(), result_json, parse_opts);
    const result = try resultFromValue(arena.allocator(), .initialize, result_value.value, parse_opts);
    try testing.expect(result == .initialize_result);
    try testing.expectEqual(@as(u32, 1), result.initialize_result.protocol);

    const auth_result = try resultFromValue(arena.allocator(), .@"auth.set_api_key", .{ .object = .empty }, parse_opts);
    try testing.expect(auth_result == .empty);

    const error_json =
        \\{"id":"req-1","error":{"code":-32602,"message":"bad request"}}
    ;
    const parsed = try std.json.parseFromSlice(ResponseError, testing.allocator, error_json, parse_opts);
    defer parsed.deinit();
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(error_json, buf.written());
}
