//! Shared request, result, state, and broadcast wire types.

const ids = @import("ids.zig");
const enums = @import("enums.zig");
const content = @import("content.zig");
const initialize = @import("initialize.zig");
const message = @import("message.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const input = @import("input.zig");

/// This payload describes `config.changed`.
pub const ConfigChangedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    config: run.RunConfig,
};

/// These are the `session.create` input fields. They borrow their data.
pub const CreateSession = struct {
    /// The workspace root. The caller names it; the engine holds no default directory.
    workspace_path: []const u8,
    profile: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    /// Replace the base prompt; child policy remains separate. Resolve placeholders at creation.
    system_prompt: ?[]const u8 = null,
    max_rounds: ?u64 = null,
    initial_input: ?input.Input = null,
    child: ?session.ChildSession = null,
};

/// This type records the creation time for a user or compaction message.
pub const CreatedTime = struct {
    created_at_ms: u64,
};

/// This type records the engine build. Its fields borrow their data.
pub const EngineInfo = struct {
    version: []const u8,
};

/// Empty params or result object.
pub const Empty = struct {};

/// This type records request failure details. Its fields borrow their data.
pub const ErrorObject = struct {
    code: enums.ErrorCode,
    message: []const u8,
};

/// This result contains the coarse engine snapshot after `initialize`.
pub const InitializeResult = struct {
    protocol: u32,
    engine: EngineInfo,
    session_revision: ids.SessionRevision,
    catalog_rev: ids.CatalogRev,
};

/// The engine broadcasts this diagnostic notice to all connections. Its fields borrow their data.
pub const Notice = struct {
    level: enums.NoticeLevel,
    source: []const u8,
    message: []const u8,
};

/// This input waits behind an active turn.
pub const QueuedInput = struct {
    /// The loaded skill body stays in content until this input commits.
    skill_name: ?[]const u8 = null,
    source: ?@import("input.zig").InputSource = null,
    input_id: ids.InputId,
    content: []const content.ContentPart,
    queued_at_ms: u64,
};

/// The engine owns this session summary.
pub const Session = struct {
    id: ids.SessionId,
    /// The canonical workspace directory this session runs in.
    root: []const u8,
    profile: []const u8,
    model: []const u8,
    reasoning: []const u8,
    config_rev: ids.ConfigRev,
    max_rounds: ?u64 = null,
    title: []const u8,
    message_count: u64,
    usage_total: message.TokenUsage,
    created_at_ms: u64,
    updated_at_ms: u64,
    created_by: ?initialize.Client = null,
    origin: session.SessionOrigin,
    agent: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// This payload describes `transcript.truncated`.
pub const TranscriptTruncatedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    first_removed_id: ids.MessageId,
};
