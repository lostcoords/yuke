//! Shared request, result, state, and broadcast wire types.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const content = @import("content.zig");
const initialize = @import("initialize.zig");
const message = @import("message.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const workspace = @import("workspace.zig");

/// This payload describes `config.changed`.
pub const ConfigChangedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    config: run.RunConfig,
};

/// These are the `session.create` input fields. They borrow their data.
pub const CreateSession = struct {
    workspace_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    permission: ?enums.PermissionMode = null,
    max_rounds: ?u64 = null,
};

/// This type records the creation time for a user or compaction message.
pub const CreatedTime = struct {
    created_at_ms: u64,
};

/// This type records daemon identity and time. Its fields borrow their data.
pub const DaemonInfo = struct {
    version: []const u8,
    server_now_ms: u64,
};

/// Empty params or result object.
pub const Empty = struct {};

/// This type records request failure details. Its fields borrow their data.
pub const ErrorObject = struct {
    code: enums.ErrorCode,
    message: []const u8,
};

/// This result contains the coarse daemon snapshot after `initialize`.
pub const InitializeResult = struct {
    protocol: u32,
    daemon: DaemonInfo,
    workspaces: []const workspace.Workspace,
    profiles: []const []const u8,
    agents: []const []const u8,
    session_revision: ids.SessionRevision,
    catalog_rev: ids.CatalogRev,
    capabilities: []const enums.Capability,
};

/// The daemon broadcasts this diagnostic notice to all connections. Its fields borrow their data.
pub const Notice = struct {
    level: enums.NoticeLevel,
    source: []const u8,
    message: []const u8,
};

/// This input waits behind an active turn.
pub const QueuedInput = struct {
    input_id: ids.InputId,
    content: []const content.ContentPart,
    queued_at_ms: u64,
};

/// The daemon owns this session summary.
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

/// This payload describes `transcript.truncated`.
pub const TranscriptTruncatedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    first_removed_id: ids.MessageId,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
