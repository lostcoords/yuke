//! RPC request, response, and notification envelopes.

const std = @import("std");
const agents = @import("agents.zig");
const auth = @import("auth.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");
const content = @import("content.zig");
const enums = @import("enums.zig");
const ids = @import("ids.zig");
const input = @import("input.zig");
const interaction = @import("interaction.zig");
const job = @import("job.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const skill = @import("skill.zig");
const tool = @import("tool.zig");

fn stringifyPayload(self: anytype, jw: *std.json.Stringify) !void {
    switch (self) {
        inline else => |payload| try jw.write(payload),
    }
}

/// This union carries client request parameters.
pub const RequestParams = union(enum) {
    agents_update_params: agents.AgentsUpdateParams,
    session_list_params: session.SessionListParams,
    session_get_params: session.SessionGetParams,
    session_goal_params: session.SessionGoalParams,
    create_session: misc.CreateSession,
    session_patch_params: session.SessionPatchParams,
    session_remove_params: session.SessionRemoveParams,
    session_fork_params: session.SessionForkParams,
    session_compact_params: session.SessionCompactParams,
    session_rewind_params: session.SessionRewindParams,
    session_send_input_params: session.SessionSendInputParams,
    session_cancel_input_params: session.SessionCancelInputParams,
    session_queue_params: session.SessionQueueParams,
    session_cancel_run_params: session.SessionCancelRunParams,
    session_history_params: session.SessionHistoryParams,
    session_config_params: session.SessionConfigParams,
    session_reload_context_params: session.SessionReloadContextParams,
    skill_load_params: skill.SkillLoadParams,
    blob_put_params: blob.BlobPutParams,
    catalog_list_params: catalog.CatalogListParams,
    empty: misc.Empty,
    auth_set_api_key_params: auth.AuthSetApiKeyParams,
    auth_login_params: auth.AuthLoginParams,
    auth_cancel_login_params: auth.AuthCancelLoginParams,
    auth_remove_params: auth.AuthRemoveParams,
    interaction_respond_params: interaction.InteractionRespondParams,
    job_list_params: job.JobListParams,
    job_stop_params: job.JobStopParams,
    job_read_params: job.JobReadParams,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try stringifyPayload(self, jw);
    }
};

/// This union carries server response results.
pub const ResponseResult = union(enum) {
    agents_get_result: agents.AgentsGetResult,
    initialize_result: misc.InitializeResult,
    session_list_result: session.SessionListResult,
    session_list_item: session.SessionListItem,
    session_goal_result: session.SessionGoalResult,
    session_result: session.SessionResult,
    session: misc.Session,
    empty: misc.Empty,
    session_compact_result: session.SessionCompactResult,
    session_send_input_result: session.SessionSendInputResult,
    session_cancel_input_result: session.SessionCancelInputResult,
    session_queue_result: session.SessionQueueResult,
    session_cancel_run_result: session.SessionCancelRunResult,
    session_history_result: session.SessionHistoryResult,
    session_config_result: session.SessionConfigResult,
    session_reload_context_result: session.SessionReloadContextResult,
    skill_load_result: skill.SkillLoadResult,
    media_blob: content.MediaBlob,
    catalog_list_result: catalog.CatalogListResult,
    catalog_reload_result: catalog.CatalogReloadResult,
    auth_list_result: auth.AuthListResult,
    auth_login_result: auth.AuthLoginResult,
    job_list_result: job.JobListResult,
    job_stop_result: job.JobStopResult,
    job_read_result: job.JobReadResult,

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try stringifyPayload(self, jw);
    }
};

/// This union carries server broadcast data.
pub const BroadcastData = union(enum) {
    session_summary_changed_data: session.SessionSummaryChangedData,
    session_activity_changed_data: session.SessionActivityChangedData,
    session_removed_data: session.SessionRemovedData,
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
    interaction_requested_data: interaction.InteractionRequestedData,
    job_changed_data: job.JobChangedData,

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
    .{ .name = .@"agents.get", .params = misc.Empty, .result = agents.AgentsGetResult, .params_optional = true },
    .{ .name = .@"agents.update", .params = agents.AgentsUpdateParams, .result = agents.AgentsGetResult, .params_optional = false },
    .{ .name = .initialize, .params = misc.Empty, .result = misc.InitializeResult, .params_optional = true },
    .{ .name = .@"session.list", .params = session.SessionListParams, .result = session.SessionListResult, .params_optional = true },
    .{ .name = .@"session.get", .params = session.SessionGetParams, .result = session.SessionListItem, .params_optional = false },
    .{ .name = .@"session.goal", .params = session.SessionGoalParams, .result = session.SessionGoalResult, .params_optional = false },
    .{ .name = .@"session.create", .params = misc.CreateSession, .result = session.SessionResult, .params_optional = false },
    .{ .name = .@"session.patch", .params = session.SessionPatchParams, .result = misc.Session, .params_optional = false },
    .{ .name = .@"session.remove", .params = session.SessionRemoveParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"session.fork", .params = session.SessionForkParams, .result = misc.Session, .params_optional = false },
    .{ .name = .@"session.compact", .params = session.SessionCompactParams, .result = session.SessionCompactResult, .params_optional = false },
    .{ .name = .@"session.rewind", .params = session.SessionRewindParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"session.send_input", .params = session.SessionSendInputParams, .result = session.SessionSendInputResult, .params_optional = false },
    .{ .name = .@"session.cancel_input", .params = session.SessionCancelInputParams, .result = session.SessionCancelInputResult, .params_optional = false },
    .{ .name = .@"session.queue", .params = session.SessionQueueParams, .result = session.SessionQueueResult, .params_optional = false },
    .{ .name = .@"session.cancel_run", .params = session.SessionCancelRunParams, .result = session.SessionCancelRunResult, .params_optional = false },
    .{ .name = .@"session.history", .params = session.SessionHistoryParams, .result = session.SessionHistoryResult, .params_optional = false },
    .{ .name = .@"session.config", .params = session.SessionConfigParams, .result = session.SessionConfigResult, .params_optional = false },
    .{ .name = .@"session.reload_context", .params = session.SessionReloadContextParams, .result = session.SessionReloadContextResult, .params_optional = false },
    .{ .name = .@"skill.load", .params = skill.SkillLoadParams, .result = skill.SkillLoadResult, .params_optional = false },
    .{ .name = .@"blob.put", .params = blob.BlobPutParams, .result = content.MediaBlob, .params_optional = false },
    .{ .name = .@"catalog.list", .params = catalog.CatalogListParams, .result = catalog.CatalogListResult, .params_optional = true },
    .{ .name = .@"catalog.reload", .params = misc.Empty, .result = catalog.CatalogReloadResult, .params_optional = true },
    .{ .name = .@"auth.list", .params = misc.Empty, .result = auth.AuthListResult, .params_optional = true },
    .{ .name = .@"auth.set_api_key", .params = auth.AuthSetApiKeyParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"auth.login", .params = auth.AuthLoginParams, .result = auth.AuthLoginResult, .params_optional = false },
    .{ .name = .@"auth.cancel_login", .params = auth.AuthCancelLoginParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"auth.remove", .params = auth.AuthRemoveParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"interaction.respond", .params = interaction.InteractionRespondParams, .result = misc.Empty, .params_optional = false },
    .{ .name = .@"job.list", .params = job.JobListParams, .result = job.JobListResult, .params_optional = true },
    .{ .name = .@"job.stop", .params = job.JobStopParams, .result = job.JobStopResult, .params_optional = false },
    .{ .name = .@"job.read", .params = job.JobReadParams, .result = job.JobReadResult, .params_optional = false },
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
    .{ .name = .@"interaction.requested", .data = interaction.InteractionRequestedData },
    .{ .name = .@"job.changed", .data = job.JobChangedData },
};

fn validateTable(comptime Name: type, comptime table: anytype) void {
    for (@typeInfo(Name).@"enum".fields) |field| {
        var count: usize = 0;
        for (table) |spec| {
            if (std.mem.eql(u8, @tagName(spec.name), field.name)) count += 1;
        }
        if (count != 1) @compileError("expected one protocol entry for " ++ field.name);
    }
}

comptime {
    @setEvalBranchQuota(10000);
    validateTable(enums.MethodName, methods);
    validateTable(enums.BroadcastName, broadcasts);
    for (methods) |spec| {
        if (spec.params_optional) {
            for (@typeInfo(spec.params).@"struct".fields) |field| {
                if (field.defaultValue() == null)
                    @compileError("optional parameters require field defaults: " ++ @tagName(spec.name));
            }
        }
    }
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

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("method");
        try jw.write(@tagName(self.method));
        try jw.objectField("params");
        try jw.write(self.params);
        try jw.endObject();
    }
};

const testing = std.testing;
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "request envelope round-trips" {
    const value: Request = .{ .id = "req-1", .method = .initialize, .params = .empty };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(
        \\{"id":"req-1","method":"initialize","params":{}}
    , buf.written());
}

test "notification envelope round-trips" {
    const json =
        \\{"method":"notice","params":{"level":"info","source":"test","message":"hello"}}
    ;
    const value: Notification = .{ .method = .notice, .params = .{ .notice = .{ .level = .info, .source = "test", .message = "hello" } } };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "response error stringifies" {
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
