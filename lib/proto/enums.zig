//! Protocol enumerations and capability sets.

const std = @import("std");

pub const AuthCredentialKind = enum { api_key, oauth };

pub const BroadcastName = enum {
    /// A session's summary metadata changed.
    @"session.summary_changed",
    /// A session's activity state changed.
    @"session.activity_changed",
    /// The engine removed a session.
    @"session.removed",
    /// The model catalog changed.
    @"catalog.changed",
    /// The engine finished an authentication login flow.
    @"auth.login_finished",
    /// Authentication state changed.
    @"auth.changed",
    /// The engine sent an out-of-band notice.
    notice,
    /// An extension asks the connected frontend to interact with the user.
    @"interaction.requested",
    /// The engine committed a message to a session transcript.
    @"message.committed",
    /// A run started.
    @"run.started",
    /// A run finished.
    @"run.done",
    /// A session's run config changed.
    @"config.changed",
    /// The engine truncated older transcript messages.
    @"transcript.truncated",
    /// A new streaming message started.
    @"message.started",
    /// The engine discarded an unfinished message.
    @"message.discarded",
    /// The engine added a part to a message.
    @"message.part_added",
    /// The engine sent more content for a message part.
    @"message.part_delta",
    /// The engine attached final metadata to a stopped part.
    @"message.part_finalized",
    /// A tool call's state changed.
    @"tool.state_changed",
    /// The engine sent more output from a tool.
    @"tool.output_delta",
    /// The engine queued an input behind the active run.
    @"input.queued",
    /// The engine canceled a queued input.
    @"input.canceled",
};

/// Run failure category.
pub const RunErrorCode = enum {
    provider,
    protocol,
    network,
    timeout,
    rate_limited,
    quota_exhausted,
    auth,
    unknown_model,
    unsupported_reasoning,
    max_rounds,
    context_overflow,
    runtime,
    internal,
};

pub const MethodName = enum {
    /// Establish the connection and negotiate the protocol version.
    initialize,
    /// List the sessions.
    @"session.list",
    /// Create a session.
    @"session.create",
    /// Update a session's mutable fields.
    @"session.patch",
    /// Remove a session.
    @"session.remove",
    /// Fork a session at a message.
    @"session.fork",
    /// Compact a session's transcript.
    @"session.compact",
    /// Rewind a session to before a message.
    @"session.rewind",
    /// Send user input to a session.
    @"session.send_input",
    /// Cancel a queued input.
    @"session.cancel_input",
    /// Cancel the active run.
    @"session.cancel_run",
    /// Fetch a page from a session transcript.
    @"session.history",
    /// Fetch a session's run config.
    @"session.config",
    /// List the model catalog.
    @"catalog.list",
    /// Refresh the model catalog from providers.
    /// List the local providers and the credential each one holds.
    @"auth.list",
    /// Set an API key for a provider.
    @"auth.set_api_key",
    /// Begin a provider login flow.
    @"auth.login",
    /// Cancel an active login flow.
    @"auth.cancel_login",
    /// Remove the credential the engine holds for a provider.
    @"auth.remove",
    /// Answer one pending extension interaction.
    @"interaction.respond",
    /// Describe one filesystem path.
    /// List the skills this session can invoke.
    @"skill.list",
};

/// Notice severity level.
pub const NoticeLevel = enum { info, warn, @"error" };

pub const RunKind = enum { turn, compaction };

pub const CompactSkipReason = enum { nothing_to_summarize, too_few_messages };

/// Assistant stop reason. `refusal` is a model decline; `content_filter` is a filter that cut content.
pub const StopReason = enum { stop, length, content_filter, refusal, tool_calls, canceled, @"error", unknown };

pub const CompactStatus = enum { started, queued };

/// Session list view.
pub const SessionView = enum { active, recent, active_recent };

pub const CompactionReason = enum { auto, manual };

/// Provider protocol kind.
pub const ProviderProtocol = enum { anthropic_messages, openai_chat, openai_responses };

/// Report whether a configured provider can serve a request now, and why it cannot.
pub const ProviderState = enum {
    ready,
    /// No credential reached the engine.
    needs_credential,
    /// A route field is missing, so the engine cannot build a request.
    needs_route,
    /// The grant expired. The user must authenticate again.
    expired,
};

pub const SkillScope = enum { project, personal };

/// Workspace execution environment.
/// Advertised engine capability.
/// Numeric JSON-RPC and yuke error codes.
pub const ErrorCode = enum(i32) {
    bad_request = -32602,
    bad_protocol = -32600,
    unknown_method = -32601,
    unknown_session = -31000,
    stale_cursor = -31002,
    unknown_message = -31003,
    unknown_part = -31004,
    unknown_input = -31005,
    unknown_config_rev = -31006,
    unknown_skill = -31009,
    input_already_started = -31010,
    queue_full = -31011,
    run_mismatch = -31012,
    session_busy = -31015,
    session_has_children = -31016,
    runtime_failed = -31017,
    invalid_patch = -31018,
    unsupported_model = -31019,
    unsupported_reasoning = -31020,
    not_implemented = -31022,
    unknown_provider = -31023,
    unknown_interaction = -31024,
    internal = -32603,
    overloaded = -31021,

    /// Decode an error code from JSON.
    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        const v = try std.json.Value.jsonParse(a, s, o);
        return jsonParseFromValue(a, v, o);
    }

    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        _ = a;
        _ = o;
        const n = switch (v) {
            .integer => |n| n,
            else => return error.UnexpectedToken,
        };
        return std.enums.fromInt(@This(), n) orelse error.InvalidEnumTag;
    }

    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        try jw.write(@intFromEnum(self));
    }
};

const testing = std.testing;

test "numeric enum round-trips as an integer" {
    const parsed = try std.json.parseFromSlice(ErrorCode, testing.allocator,
        \\-31000
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(ErrorCode.unknown_session, parsed.value);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(ErrorCode.unknown_session, .{}, &buf.writer);
    try testing.expectEqualStrings("-31000", buf.written());
}

test "numeric enum rejects unknown code" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(ErrorCode, testing.allocator,
        \\-99999
    , .{}));
}
