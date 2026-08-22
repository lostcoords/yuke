//! Miscellaneous shared request, result, state, and broadcast wire types.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const content = @import("content.zig");
const catalog = @import("catalog.zig");
const initialize = @import("initialize.zig");
const message = @import("message.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const workspace = @import("workspace.zig");

/// Payload for `config.changed`.
pub const ConfigChangedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    config: run.RunConfig,
};

/// session.create input. Non-owning.
pub const CreateSession = struct {
    workspace_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    permission: ?enums.PermissionMode = null,
    max_rounds: ?u64 = null,
};

/// Creation timestamp for a user or compaction message.
pub const CreatedTime = struct {
    created_at_ms: u64,
};

/// Daemon identity and clock. Non-owning.
pub const DaemonInfo = struct {
    version: []const u8,
    server_now_ms: u64,
};

/// Empty params or result object.
pub const Empty = struct {};

/// Request failure details. Non-owning.
pub const ErrorObject = struct {
    code: enums.ErrorCode,
    message: []const u8,
};

/// Result of the `initialize` request: the coarse daemon snapshot.
pub const InitializeResult = struct {
    protocol: u32,
    daemon: DaemonInfo,
    workspaces: []const workspace.Workspace,
    profiles: []const []const u8,
    agents: []const []const u8,
    session_revision: ids.SessionRevision,
    cron_revision: ids.CronRevision,
    catalog_rev: ids.CatalogRev,
    catalog_health: catalog.CatalogHealth,
    capabilities: []const enums.Capability,
};

/// Daemon diagnostic notice broadcast to all connections. Non-owning.
pub const Notice = struct {
    level: enums.NoticeLevel,
    source: []const u8,
    message: []const u8,
};

/// A queued input waiting behind an active turn.
pub const QueuedInput = struct {
    input_id: ids.InputId,
    content: []const content.ContentPart,
    queued_at_ms: u64,
};

/// Daemon-owned session summary.
pub const Session = struct {
    id: ids.SessionId,
    workspace_id: ids.WorkspaceId,
    profile: []const u8,
    model: []const u8,
    reasoning: []const u8,
    config_rev: ids.ConfigRev,
    permission: enums.PermissionMode,
    max_rounds: ?u64 = null,
    title: []const u8,
    message_count: u64,
    usage_total: message.TokenUsage,
    created_at_ms: u64,
    updated_at_ms: u64,
    created_by: ?initialize.Client = null,
    origin: session.SessionOrigin,
    agent: ?[]const u8 = null,
};

/// Payload for `transcript.truncated`.
pub const TranscriptTruncatedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    first_removed_id: ids.MessageId,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "create session optional fields default to null and are omitted" {
    const parsed = try std.json.parseFromSlice(CreateSession, testing.allocator, "{}", opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.workspace_path == null);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings("{}", buf.written());
}
