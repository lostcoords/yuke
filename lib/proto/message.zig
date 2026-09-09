//! Session message and content-part wire types.

const std = @import("std");
const content = @import("content.zig");
const enums = @import("enums.zig");
const ids = @import("ids.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");
const tool = @import("tool.zig");
const view = @import("view.zig");

/// This is the assistant draft that a run streams. Its fields borrow their data.
pub const ActiveDraft = struct {
    message: AssistantMessage,
};

/// This payload describes an assistant transcript message. Its fields borrow their data.
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

/// This type describes one element of an assistant message's content. Its fields borrow their data.
pub const AssistantPart = union(enum) {
    text: TextPart,
    reasoning: ReasoningPart,
    redacted_reasoning: RedactedReasoningPart,
    tool: ToolPart,

    /// Return the part id. Each arm carries the same field.
    pub fn id(self: @This()) ids.PartId {
        return switch (self) {
            inline else => |p| p.id,
        };
    }

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

/// This payload describes a compaction transcript message. Its fields borrow their data.
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

/// This union describes a transcript message. Its fields borrow their data.
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    compaction: CompactionMessage,

    /// Return the message id. Each arm carries the same field.
    pub fn id(self: @This()) ids.MessageId {
        return switch (self) {
            inline else => |m| m.id,
        };
    }

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

/// This payload describes `message.committed`.
pub const MessageCommittedData = struct {
    session_id: ids.SessionId,
    seq: ids.Seq,
    message: Message,
};

/// This payload describes `message.discarded`.
pub const MessageDiscardedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
};

/// This type describes an assistant error with `finish: "error"`. Its fields borrow their data.
pub const MessageError = struct {
    type: []const u8,
    message: []const u8,
};

/// This payload describes `message.part_added`.
pub const MessagePartAddedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part: AssistantPart,
};

/// This payload describes `message.started` when the engine opens a draft.
pub const MessageStartedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    run_id: ids.RunId,
    config_rev: ids.ConfigRev,
    agent: []const u8,
    created_at_ms: u64,
};

/// Creation and completion times for an assistant message.
pub const MessageTime = struct {
    created_at_ms: u64,
    completed_at_ms: ?u64 = null,
};

/// This payload holds more text or reasoning bytes for a draft.
pub const PartDelta = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    delta: []const u8,
    offset: u64,
};

/// The broadcast uses this shared message-part delta payload.
pub const MessagePartDeltaData = PartDelta;

/// The broadcast uses this shared tool-output delta payload.
pub const ToolOutputDeltaData = PartDelta;

/// The final metadata for a stopped reasoning part. Tool parts finalize through `tool.state_changed`.
pub const PartFinal = union(enum) {
    reasoning: ReasoningFinal,
    redacted_reasoning: RedactedReasoningFinal,

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

/// The engine attaches the reasoning signature at block stop. An empty string means none.
pub const ReasoningFinal = struct {
    signature: []const u8,
};

/// The engine attaches the opaque redacted reasoning data at block stop.
pub const RedactedReasoningFinal = struct {
    data: []const u8,
};

/// This payload describes `message.part_finalized`. The engine sends it at block stop.
pub const MessagePartFinalizedData = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    final: PartFinal,
};

/// This payload describes a reasoning part in an assistant message. Its fields borrow their data.
pub const ReasoningPart = struct {
    id: ids.PartId,
    text: []const u8,
    signature: []const u8,
};

/// This payload holds opaque, safety-redacted model reasoning. Its fields borrow their data.
pub const RedactedReasoningPart = struct {
    id: ids.PartId,
    data: []const u8,
};

/// This payload describes a text part in an assistant message. Its fields borrow their data.
pub const TextPart = struct {
    id: ids.PartId,
    text: []const u8,
};

/// This type records token counts for one assistant message.
pub const TokenUsage = struct {
    input: u64,
    output: u64,
    reasoning: u64,
    cache_read: u64,
    cache_write: u64,

    pub const zero: TokenUsage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 };
};

/// This payload describes a tool part in an assistant message. Its fields borrow their data.
pub const ToolPart = struct {
    id: ids.PartId,
    call_id: ?[]const u8 = null,
    name: []const u8,
    arguments: []const u8,
    input_view: ?[]const view.View = null,
    state: tool.ToolState,
};

/// This type records the provider that produced an assistant turn. Its fields borrow their data.
pub const TurnProvenance = struct {
    protocol: enums.ProviderProtocol,
    model: []const u8,
};

/// This payload describes a user transcript message. Its fields borrow their data.
pub const UserMessage = struct {
    /// Native admission records the skill name beside its exact text.
    skill_name: ?[]const u8 = null,
    source: ?@import("input.zig").InputSource = null,
    id: ids.MessageId,
    content: []const content.ContentPart,
    input_id: ids.InputId,
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

test "part final reasoning variant round-trips" {
    const json =
        \\{"type":"reasoning","signature":"sig"}
    ;
    const parsed = try std.json.parseFromSlice(PartFinal, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .reasoning);
    try testing.expectEqualStrings("sig", parsed.value.reasoning.signature);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}

test "part final redacted variant round-trips" {
    const json =
        \\{"type":"redacted_reasoning","data":"opaque"}
    ;
    const parsed = try std.json.parseFromSlice(PartFinal, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .redacted_reasoning);
    try testing.expectEqualStrings("opaque", parsed.value.redacted_reasoning.data);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
