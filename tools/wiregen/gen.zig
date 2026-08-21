//! Generate the wire protocol meta-model from the Zig wire declarations.

const std = @import("std");

const wire = @import("wire");
const doc_extractor = @import("docs.zig");
const registry = wire.registry;
const initialize = wire.initialize;
const enums = wire.enums;
const meta = wire.meta;
const rpc = wire.rpc;

const TypeEntry = registry.TypeEntry;
const EnumEntry = struct { name: []const u8, ty: type, numeric: bool };
const AliasUse = struct { owner: []const u8, field: []const u8, alias: []const u8 };

const alias_uses = [_]AliasUse{
    .{ .owner = "AuthLoginSummary", .field = "login_id", .alias = "LoginId" },
    .{ .owner = "AuthProvider", .field = "provider_id", .alias = "ProviderId" },
    .{ .owner = "AuthLoginParams", .field = "provider_id", .alias = "ProviderId" },
    .{ .owner = "AuthLoginResultBrowser", .field = "login_id", .alias = "LoginId" },
    .{ .owner = "AuthLoginResultDeviceCode", .field = "login_id", .alias = "LoginId" },
    .{ .owner = "AuthCancelLoginParams", .field = "login_id", .alias = "LoginId" },
    .{ .owner = "AuthLogoutParams", .field = "provider_id", .alias = "ProviderId" },
    .{ .owner = "AuthSetApiKeyParams", .field = "provider_id", .alias = "ProviderId" },
    .{ .owner = "AuthLoginFinishedData", .field = "login_id", .alias = "LoginId" },
    .{ .owner = "AuthLoginFinishedData", .field = "provider_id", .alias = "ProviderId" },
    .{ .owner = "SessionSummaryChangedData", .field = "revision", .alias = "SessionRevision" },
    .{ .owner = "SessionActivityChangedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionRemovedData", .field = "revision", .alias = "SessionRevision" },
    .{ .owner = "SessionRemovedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "WorkspaceRemovedData", .field = "workspace_id", .alias = "WorkspaceId" },
    .{ .owner = "PermissionRulesChangedData", .field = "workspace_id", .alias = "WorkspaceId" },
    .{ .owner = "CatalogChangedData", .field = "catalog_rev", .alias = "CatalogRev" },
    .{ .owner = "CronCreatedData", .field = "revision", .alias = "CronRevision" },
    .{ .owner = "CronUpdatedData", .field = "revision", .alias = "CronRevision" },
    .{ .owner = "CronRemovedData", .field = "revision", .alias = "CronRevision" },
    .{ .owner = "CronRemovedData", .field = "job_id", .alias = "JobId" },
    .{ .owner = "MessageCommittedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "MessageCommittedData", .field = "seq", .alias = "Seq" },
    .{ .owner = "RunStartedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "RunStartedData", .field = "seq", .alias = "Seq" },
    .{ .owner = "RunStartedData", .field = "run_id", .alias = "RunId" },
    .{ .owner = "RunStartedData", .field = "config_rev", .alias = "ConfigRev" },
    .{ .owner = "RunDoneData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "RunDoneData", .field = "seq", .alias = "Seq" },
    .{ .owner = "RunDoneData", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ConfigChangedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "ConfigChangedData", .field = "seq", .alias = "Seq" },
    .{ .owner = "TranscriptTruncatedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "TranscriptTruncatedData", .field = "seq", .alias = "Seq" },
    .{ .owner = "TranscriptTruncatedData", .field = "first_removed_id", .alias = "MessageId" },
    .{ .owner = "MessageStartedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "MessageStartedData", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "MessageStartedData", .field = "run_id", .alias = "RunId" },
    .{ .owner = "MessageStartedData", .field = "config_rev", .alias = "ConfigRev" },
    .{ .owner = "MessageDiscardedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "MessageDiscardedData", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "MessagePartAddedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "MessagePartAddedData", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "ToolStateChangedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "ToolStateChangedData", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "ToolStateChangedData", .field = "part_id", .alias = "PartId" },
    .{ .owner = "InputQueuedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "InputCanceledData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "InputCanceledData", .field = "input_id", .alias = "InputId" },
    .{ .owner = "SessionDeltasShedData", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "ModelInfo", .field = "id", .alias = "ModelId" },
    .{ .owner = "CatalogListParams", .field = "since_rev", .alias = "CatalogRev" },
    .{ .owner = "CatalogListResultUnchanged", .field = "catalog_rev", .alias = "CatalogRev" },
    .{ .owner = "CatalogListResultFull", .field = "catalog_rev", .alias = "CatalogRev" },
    .{ .owner = "CatalogRefreshResult", .field = "catalog_rev", .alias = "CatalogRev" },
    .{ .owner = "CronPatchParams", .field = "job_id", .alias = "JobId" },
    .{ .owner = "CronJobRef", .field = "job_id", .alias = "JobId" },
    .{ .owner = "CronListResult", .field = "revision", .alias = "CronRevision" },
    .{ .owner = "CronRunNowResult", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "CronRunNowResult", .field = "run_id", .alias = "RunId" },
    .{ .owner = "CronJob", .field = "id", .alias = "JobId" },
    .{ .owner = "CronJob", .field = "last_session_id", .alias = "SessionId" },
    .{ .owner = "Request", .field = "id", .alias = "RequestId" },
    .{ .owner = "ResponseOk", .field = "id", .alias = "RequestId" },
    .{ .owner = "ResponseError", .field = "id", .alias = "RequestId" },
    .{ .owner = "InitializeResult", .field = "session_revision", .alias = "SessionRevision" },
    .{ .owner = "InitializeResult", .field = "cron_revision", .alias = "CronRevision" },
    .{ .owner = "InitializeResult", .field = "catalog_rev", .alias = "CatalogRev" },
    .{ .owner = "QueuedInput", .field = "input_id", .alias = "InputId" },
    .{ .owner = "SessionSendInputParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionSendInputResultStarted", .field = "input_id", .alias = "InputId" },
    .{ .owner = "SessionSendInputResultStarted", .field = "run_id", .alias = "RunId" },
    .{ .owner = "SessionSendInputResultQueued", .field = "input_id", .alias = "InputId" },
    .{ .owner = "SessionCancelInputParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionCancelInputParams", .field = "input_id", .alias = "InputId" },
    .{ .owner = "SessionCancelInputResult", .field = "canceled_input", .alias = "InputId" },
    .{ .owner = "SessionCancelRunParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionCancelRunParams", .field = "run_id", .alias = "RunId" },
    .{ .owner = "SessionCancelRunResult", .field = "canceled_run", .alias = "RunId" },
    .{ .owner = "SessionCancelRunResult", .field = "cleared_inputs", .alias = "InputId" },
    .{ .owner = "SessionCancelRunResult", .field = "cleared_compaction", .alias = "RunId" },
    .{ .owner = "PartDelta", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "PartDelta", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "PartDelta", .field = "part_id", .alias = "PartId" },
    .{ .owner = "SessionPatchParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionRemoveParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "PermissionDecisionRule", .field = "rule_id", .alias = "RuleId" },
    .{ .owner = "PermissionRule", .field = "id", .alias = "RuleId" },
    .{ .owner = "PermissionRule", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "PermissionDecideParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "PermissionDecideParams", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "PermissionDecideParams", .field = "part_id", .alias = "PartId" },
    .{ .owner = "PermissionForgetParams", .field = "workspace_id", .alias = "WorkspaceId" },
    .{ .owner = "PermissionForgetParams", .field = "rule_id", .alias = "RuleId" },
    .{ .owner = "RunOutcomeCompacted", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "SessionForkParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionForkParams", .field = "before_message_id", .alias = "MessageId" },
    .{ .owner = "SessionCompactParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionCompactResult", .field = "run_id", .alias = "RunId" },
    .{ .owner = "SessionRewindParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionRewindParams", .field = "before_message_id", .alias = "MessageId" },
    .{ .owner = "SessionOriginChild", .field = "parent_id", .alias = "SessionId" },
    .{ .owner = "SessionOriginChild", .field = "parent_message_id", .alias = "MessageId" },
    .{ .owner = "SessionOriginChild", .field = "parent_part_id", .alias = "PartId" },
    .{ .owner = "SessionOriginFork", .field = "source_id", .alias = "SessionId" },
    .{ .owner = "SessionOriginCron", .field = "job_id", .alias = "JobId" },
    .{ .owner = "Session", .field = "id", .alias = "SessionId" },
    .{ .owner = "Session", .field = "workspace_id", .alias = "WorkspaceId" },
    .{ .owner = "Session", .field = "config_rev", .alias = "ConfigRev" },
    .{ .owner = "RunConfig", .field = "config_rev", .alias = "ConfigRev" },
    .{ .owner = "SessionActivity", .field = "pending_compaction", .alias = "RunId" },
    .{ .owner = "SessionScopeWorkspace", .field = "workspace_id", .alias = "WorkspaceId" },
    .{ .owner = "SessionPopulationChildren", .field = "parent_id", .alias = "SessionId" },
    .{ .owner = "SessionPopulationJobRuns", .field = "job_id", .alias = "JobId" },
    .{ .owner = "SessionListResult", .field = "revision", .alias = "SessionRevision" },
    .{ .owner = "ActivityStateBuilding", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ActivityStateRunning", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ActivityStateReasoning", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ActivityStateReasoning", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "ActivityStateReasoning", .field = "part_id", .alias = "PartId" },
    .{ .owner = "ActivityStateWaitingPermission", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ActivityStateWaitingPermission", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "ActivityStateWaitingPermission", .field = "part_id", .alias = "PartId" },
    .{ .owner = "ActivityStateRunningTool", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ActivityStateRunningTool", .field = "message_id", .alias = "MessageId" },
    .{ .owner = "ActivityStateRunningTool", .field = "part_id", .alias = "PartId" },
    .{ .owner = "ActivityStateRetrying", .field = "run_id", .alias = "RunId" },
    .{ .owner = "ActivityStateCompacting", .field = "run_id", .alias = "RunId" },
    .{ .owner = "SessionResyncParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionResyncResult", .field = "base_seq", .alias = "Seq" },
    .{ .owner = "SessionResyncResult", .field = "highest_finalized_message_id", .alias = "MessageId" },
    .{ .owner = "SessionHistoryParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionHistoryParams", .field = "before_message_id", .alias = "MessageId" },
    .{ .owner = "SessionHistoryResult", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionConfigParams", .field = "session_id", .alias = "SessionId" },
    .{ .owner = "SessionConfigParams", .field = "config_rev", .alias = "ConfigRev" },
    .{ .owner = "SubscriptionSetParams", .field = "sessions", .alias = "SessionId" },
    .{ .owner = "TextPart", .field = "id", .alias = "PartId" },
    .{ .owner = "ReasoningPart", .field = "id", .alias = "PartId" },
    .{ .owner = "RedactedReasoningPart", .field = "id", .alias = "PartId" },
    .{ .owner = "ToolPart", .field = "id", .alias = "PartId" },
    .{ .owner = "UserMessage", .field = "id", .alias = "MessageId" },
    .{ .owner = "UserMessage", .field = "input_id", .alias = "InputId" },
    .{ .owner = "AssistantMessage", .field = "id", .alias = "MessageId" },
    .{ .owner = "AssistantMessage", .field = "run_id", .alias = "RunId" },
    .{ .owner = "AssistantMessage", .field = "config_rev", .alias = "ConfigRev" },
    .{ .owner = "CompactionMessage", .field = "id", .alias = "MessageId" },
    .{ .owner = "CompactionMessage", .field = "run_id", .alias = "RunId" },
    .{ .owner = "CompactionMessage", .field = "first_kept_id", .alias = "MessageId" },
    .{ .owner = "Workspace", .field = "id", .alias = "WorkspaceId" },
    .{ .owner = "WorkspaceRef", .field = "workspace_id", .alias = "WorkspaceId" },
    .{ .owner = "WorkspaceRemoveResult", .field = "related_job_ids", .alias = "JobId" },
};

fn shortName(comptime name: []const u8) []const u8 {
    const index = comptime std.mem.lastIndexOfScalar(u8, name, '.');
    return if (index) |i| name[i + 1 ..] else name;
}

fn aliasFor(comptime owner: []const u8, comptime field: []const u8) ?[]const u8 {
    inline for (alias_uses) |use| {
        if (std.mem.eql(u8, owner, use.owner) and std.mem.eql(u8, field, use.field)) return use.alias;
    }
    return null;
}

fn writeTypeText(w: *std.Io.Writer, comptime owner: []const u8, comptime field: []const u8, comptime T: type) !void {
    if (comptime aliasFor(owner, field)) |alias| {
        switch (@typeInfo(T)) {
            // Optionality is carried by "presence"; the type is the underlying type.
            .optional => try w.writeAll(alias),
            .pointer => {
                if (T == []const u8) return w.writeAll(alias);
                try w.writeAll("[]");
                try w.writeAll(alias);
            },
            else => try w.writeAll(alias),
        }
        return;
    }
    switch (@typeInfo(T)) {
        // Optionality is carried by "presence"; emit only the underlying type.
        .optional => |optional| try writeTypeText(w, owner, field, optional.child),
        .pointer => |pointer| {
            if (pointer.child == u8) {
                try w.writeAll("string");
            } else {
                try w.writeAll("[]");
                try writeTypeText(w, owner, field, pointer.child);
            }
        },
        .array => |array| {
            try w.print("[{d}]", .{array.len});
            try writeTypeText(w, owner, field, array.child);
        },
        .int, .bool, .float => try w.writeAll(@typeName(T)),
        .@"struct", .@"enum", .@"union" => try w.writeAll(shortName(@typeName(T))),
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    }
}

fn typeText(a: std.mem.Allocator, comptime owner: []const u8, comptime field: []const u8, comptime T: type) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    try writeTypeText(&text.writer, owner, field, T);
    return text.written();
}

fn fieldDoc(a: std.mem.Allocator, docs: *const std.StringHashMap([]const u8), owner: []const u8, field: []const u8) !?[]const u8 {
    const key = try std.fmt.allocPrint(a, "{s}.{s}", .{ owner, field });
    return docs.get(key);
}

fn writeStruct(a: std.mem.Allocator, jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), entry: TypeEntry) !void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(entry.name);
    if (docs.get(entry.name)) |doc| {
        try jw.objectField("doc");
        try jw.write(doc);
    }
    try jw.objectField("fields");
    try jw.beginArray();
    inline for (@typeInfo(entry.ty).@"struct".fields) |field| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(field.name);
        if (try fieldDoc(a, docs, entry.name, field.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.objectField("type");
        try jw.write(try typeText(a, entry.name, field.name, field.type));
        try jw.objectField("presence");
        try jw.write(if (@typeInfo(field.type) == .optional) "optional" else if (field.defaultValue() != null) "defaulted" else "required");
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeUnion(a: std.mem.Allocator, jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), entry: TypeEntry, envelope: bool) !void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(entry.name);
    if (docs.get(entry.name)) |doc| {
        try jw.objectField("doc");
        try jw.write(doc);
    }
    try jw.objectField("discriminator");
    try jw.write(if (envelope) "" else "type");
    try jw.objectField("arms");
    try jw.beginArray();
    inline for (@typeInfo(entry.ty).@"union".fields) |field| {
        try jw.beginObject();
        if (!envelope) {
            try jw.objectField("tag");
            try jw.write(field.name);
        }
        if (try fieldDoc(a, docs, entry.name, field.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.objectField("type");
        if (std.mem.eql(u8, entry.name, "BroadcastData") and std.mem.eql(u8, field.name, "message_part_delta_data")) {
            try jw.write("MessagePartDeltaData");
        } else if (std.mem.eql(u8, entry.name, "BroadcastData") and std.mem.eql(u8, field.name, "tool_output_delta_data")) {
            try jw.write("ToolOutputDeltaData");
        } else {
            try jw.write(shortName(@typeName(field.type)));
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeEnum(a: std.mem.Allocator, jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), entry: EnumEntry) !void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(entry.name);
    if (docs.get(entry.name)) |doc| {
        try jw.objectField("doc");
        try jw.write(doc);
    }
    try jw.objectField("numeric");
    try jw.write(entry.numeric);
    try jw.objectField("values");
    try jw.beginArray();
    inline for (@typeInfo(entry.ty).@"enum".fields) |field| {
        try jw.beginObject();
        try jw.objectField("wire");
        if (entry.numeric) try jw.write(try std.fmt.allocPrint(a, "{d}", .{field.value})) else try jw.write(field.name);
        if (try fieldDoc(a, docs, entry.name, field.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeNamespace(jw: *std.json.Stringify, comptime T: type) !void {
    try jw.beginObject();
    inline for (@typeInfo(T).@"struct".decls) |decl| {
        try jw.objectField(decl.name);
        try jw.write(@field(T, decl.name));
    }
    try jw.endObject();
}

fn writeMethods(jw: *std.json.Stringify) !void {
    try jw.beginArray();
    inline for (rpc.methods) |spec| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(@tagName(spec.name));
        try jw.objectField("params");
        try jw.write(shortName(@typeName(spec.params)));
        try jw.objectField("result");
        try jw.write(shortName(@typeName(spec.result)));
        try jw.objectField("direction");
        try jw.write("clientToServer");
        try jw.endObject();
    }
    try jw.endArray();
}

fn broadcastType(comptime name: []const u8, comptime T: type) []const u8 {
    if (std.mem.eql(u8, name, "message.part_delta")) return "MessagePartDeltaData";
    if (std.mem.eql(u8, name, "tool.output_delta")) return "ToolOutputDeltaData";
    return shortName(@typeName(T));
}

fn writeBroadcasts(jw: *std.json.Stringify) !void {
    try jw.beginArray();
    inline for (rpc.broadcasts) |spec| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(@tagName(spec.name));
        try jw.objectField("params");
        try jw.write(broadcastType(@tagName(spec.name), spec.data));
        try jw.objectField("direction");
        try jw.write("serverToClient");
        try jw.endObject();
    }
    try jw.endArray();
}

fn writeDeliveryClasses(jw: *std.json.Stringify) !void {
    try jw.beginArray();
    inline for (@typeInfo(meta.DeliveryClass).@"enum".fields) |field| {
        const class = @field(meta.DeliveryClass, field.name);
        const props = class.props();
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(field.name);
        try jw.objectField("gated");
        try jw.write(props.gated);
        try jw.objectField("droppable");
        try jw.write(props.droppable);
        try jw.objectField("sequenced");
        try jw.write(props.sequenced);
        try jw.endObject();
    }
    try jw.endArray();
}

pub fn emit(a: std.mem.Allocator, io: std.Io, w: *std.Io.Writer) !void {
    var docs = try doc_extractor.load(a, io);
    defer docs.deinit();
    var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("protocolVersion");
    try jw.write(initialize.protocol_version);
    try jw.objectField("limits");
    try writeNamespace(&jw, meta.limits);
    try jw.objectField("constants");
    try writeNamespace(&jw, meta.constants);
    try jw.objectField("stringConstants");
    try writeNamespace(&jw, meta.string_constants);
    try jw.objectField("closeCodes");
    try writeNamespace(&jw, meta.close_codes);
    try jw.objectField("methods");
    try writeMethods(&jw);
    try jw.objectField("broadcasts");
    try writeBroadcasts(&jw);
    try jw.objectField("deliveryClasses");
    try writeDeliveryClasses(&jw);
    try jw.objectField("structures");
    try jw.beginArray();
    inline for (registry.structs) |entry| try writeStruct(a, &jw, &docs, entry);
    try jw.endArray();
    try jw.objectField("unions");
    try jw.beginArray();
    inline for (registry.tagged_unions) |entry| try writeUnion(a, &jw, &docs, entry, false);
    inline for (registry.envelope_unions) |entry| try writeUnion(a, &jw, &docs, entry, true);
    try jw.endArray();
    try jw.objectField("enumerations");
    try jw.beginArray();
    inline for (registry.enum_order) |ordered| try writeEnum(a, &jw, &docs, .{
        .name = ordered.entry.name,
        .ty = ordered.entry.ty,
        .numeric = ordered.numeric,
    });
    try jw.endArray();
    try jw.objectField("aliases");
    try jw.beginArray();
    inline for (registry.aliases) |entry| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(entry.name);
        try jw.objectField("base");
        try jw.write(entry.base);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try emit(init.arena.allocator(), init.io, &stdout.interface);
    try stdout.interface.flush();
}
