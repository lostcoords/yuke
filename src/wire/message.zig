//! Session message and content-part wire types.

const std = @import("std");
const content = @import("content.zig");
const enums = @import("enums.zig");
const ids = @import("ids.zig");
const misc = @import("misc.zig");
const permission = @import("permission.zig");
const tagged = @import("tagged.zig");
const tool = @import("tool.zig");
const view = @import("view.zig");
const workspace = @import("workspace.zig");

/// In-flight assistant draft, resent on resync. Non-owning.
pub const ActiveDraft = struct {
    message: AssistantMessage,
};

/// Assistant transcript message payload. Non-owning.
pub const AssistantMessage = struct {
    id: ids.MessageId,
    run_id: ids.RunId,
    config_rev: ids.ConfigRev,
    agent: []const u8,
    content: []const AssistantPart,
    finish: ?enums.StopReason = null,
    tokens: ?TokenUsage = null,
    cost: ?f64 = null,
    time: MessageTime,
    @"error": ?MessageError = null,
    provenance: ?TurnProvenance = null,
};

/// One element of an assistant message `content[]`. Non-owning.
pub const AssistantPart = union(enum) {
    text: TextPart,
    reasoning: ReasoningPart,
    redacted_reasoning: RedactedReasoningPart,
    tool: ToolPart,

    /// Decode a tagged wire union from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return tagged.jsonParse(@This(), a, s, o);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        return tagged.fromValue(@This(), a, v, o);
    }
    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        return tagged.stringify(@This(), self, jw);
    }
};

/// Compaction transcript message payload. Non-owning.
pub const CompactionMessage = struct {
    id: ids.MessageId,
    run_id: ids.RunId,
    reason: enums.CompactionReason,
    summary: []const u8,
    first_kept_id: ?ids.MessageId = null,
    tokens_before: u64,
    tokens_after: u64,
    time: misc.CreatedTime,
};

/// A transcript message. Non-owning.
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    compaction: CompactionMessage,

    /// Decode a tagged wire union from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return tagged.jsonParse(@This(), a, s, o);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        return tagged.fromValue(@This(), a, v, o);
    }
    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        return tagged.stringify(@This(), self, jw);
    }
};

/// Payload for `message.committed`.
pub const MessageCommittedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    message: Message,
};

/// Payload for `message.discarded`.
pub const MessageDiscardedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
};

/// Structured error on an assistant message with `finish: "error"`. Non-owning.
pub const MessageError = struct {
    type: []const u8,
    message: []const u8,
};

/// Payload for `message.part_added`.
pub const MessagePartAddedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part: AssistantPart,
};

/// Payload for `message.started` (draft opened).
pub const MessageStartedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    run_id: ids.RunId,
    config_rev: ids.ConfigRev,
    agent: []const u8,
    created_at_ms: u64,
};

/// Creation/completion timestamps on an assistant message.
pub const MessageTime = struct {
    created_at_ms: u64,
    completed_at_ms: ?u64 = null,
};

/// Incremental text or reasoning bytes for a draft.
pub const PartDelta = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    delta: []const u8,
    offset: u64,
};

/// Message part-delta broadcast payload alias.
pub const MessagePartDeltaData = PartDelta;

/// Tool output-delta broadcast payload alias.
pub const ToolOutputDeltaData = PartDelta;

/// Reasoning assistant part payload. Non-owning.
pub const ReasoningPart = struct {
    id: ids.PartId,
    text: []const u8,
    signature: []const u8,
};

/// Opaque safety-redacted model reasoning payload. Non-owning.
pub const RedactedReasoningPart = struct {
    id: ids.PartId,
    data: []const u8,
};

/// Text assistant part payload. Non-owning.
pub const TextPart = struct {
    id: ids.PartId,
    text: []const u8,
};

/// Token accounting for one assistant message.
pub const TokenUsage = struct {
    input: u64,
    output: u64,
    reasoning: u64,
    cache_read: u64,
    cache_write: u64,
};

/// Tool assistant part payload. Non-owning.
pub const ToolPart = struct {
    id: ids.PartId,
    call_id: ?[]const u8 = null,
    name: []const u8,
    arguments: []const u8,
    input_view: ?[]const view.View = null,
    state: tool.ToolState,
    permission_state: ?permission.PermissionState = null,
};

/// Provider that produced an assistant turn. Non-owning.
pub const TurnProvenance = struct {
    protocol: enums.ProviderProtocol,
    model: []const u8,
};

/// User transcript message payload. Non-owning.
pub const UserMessage = struct {
    id: ids.MessageId,
    content: []const content.ContentPart,
    input_id: ids.InputId,
    skill: ?workspace.SkillRef = null,
    time: misc.CreatedTime,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "assistant part union round-trips" {
    const json =
        \\{"type":"text","id":7,"text":"hello"}
    ;
    const parsed = try std.json.parseFromSlice(AssistantPart, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .text);
    try testing.expectEqual(@as(ids.PartId, 7), parsed.value.text.id);
    try testing.expectEqualStrings("hello", parsed.value.text.text);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
