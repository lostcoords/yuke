//! Project one provider failure onto the wire. The library owns the error table.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");

pub const Class = ai.failure.Class;

/// One error row. The wire message exposes no internal error name.
pub const Detail = struct {
    class: Class,
    code: proto.enums.RunErrorCode,
    message: []const u8,
};

/// Classify one run failure. The engine's own errors answer here; the rest come from the library.
pub fn classify(err: anyerror) Detail {
    return switch (err) {
        // The library never raises these, because they are decisions the engine makes.
        error.ContextHistoryTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the context exceeds the model budget and has no useful compaction cut" },
        error.CompactionSourceTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the history is too large for one summary request" },
        error.CompactionDidNotFit => .{ .class = .permanent, .code = .context_overflow, .message = "the summary and retained history do not reduce the context to fit the model budget" },
        error.IncompleteSummary => .{ .class = .permanent, .code = .provider, .message = "the model did not complete the summary; the context is unchanged" },
        error.EmptySummary => .{ .class = .permanent, .code = .provider, .message = "the model returned an empty summary; the context is unchanged" },
        error.TurnTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the turn is larger than the model context window" },
        error.ContextTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the prompt, tools, and output reserve exceed the model context budget" },
        error.UnsupportedReasoning => .{ .class = .permanent, .code = .unsupported_reasoning, .message = "the model does not support this reasoning level" },
        error.PromptTooLarge => .{ .class = .permanent, .code = .runtime, .message = "the system prompt exceeds the protocol string limit" },
        error.HookBlocked => .{ .class = .permanent, .code = .runtime, .message = "an extension stopped the request" },
        error.UnresolvedBlob => .{ .class = .permanent, .code = .runtime, .message = "an attachment names bytes the blob store does not hold" },
        error.MissingCredential => .{ .class = .permanent, .code = .auth, .message = "the provider has no usable credential; log in again or set its key" },
        else => {
            const got = ai.failure.classify(err);
            return .{ .class = got.class, .code = codeOf(got.reason), .message = got.reason.message() };
        },
    };
}

/// Name the wire code for one library reason. A new reason must answer here.
fn codeOf(reason: ai.failure.Reason) proto.enums.RunErrorCode {
    return switch (reason) {
        .rate_limited, .rate_limit_unknown => .rate_limited,
        .stream_timeout => .timeout,
        .connect_failed, .dns_failed, .stream_truncated, .connection_lost, .trust_store_failed => .network,
        .malformed_stream, .redirect_refused, .stream_too_large => .protocol,
        .auth_rejected, .permission_denied => .auth,
        .quota_exhausted => .quota_exhausted,
        .out_of_memory, .unknown => .internal,
        .request_too_large, .context_overflow => .context_overflow,
        .malformed_selector, .unknown_provider, .unknown_model => .unknown_model,
        .server_error, .bad_status, .bad_url, .invalid_headers, .provider_failed => .provider,
        .invalid_request, .unsupported_content, .header_conflict => .runtime,
        .invalid_credential => .auth,
        .canceled => .interrupted,
    };
}

/// Describe one run failure for the wire; `info` holds what the provider answered, and the result lives in `arena`.
pub fn outcome(arena: std.mem.Allocator, err: anyerror, info: *const ai.transport.AttemptInfo) proto.run.RunOutcomeFailed {
    const detail = classify(err);
    return .{
        .code = detail.code,
        .message = detail.message,
        .status = info.status,
        .request_id = if (info.request_id) |id| arena.dupe(u8, id) catch unreachable else null,
        // An internal error names itself, because no provider answer explains it.
        .detail = if (info.body) |body| ai.failure.detailText(arena, body) catch unreachable else if (detail.code == .internal) @errorName(err) else null,
    };
}

const testing = std.testing;

test "every transport class reports a network or timeout code" {
    // A retryable connection fault must never reach the client as a generic provider failure.
    for ([_]anyerror{
        ai.transport.HttpError.ConnectFailed,
        ai.transport.HttpError.ConnectionLost,
        ai.transport.HttpError.DnsFailed,
        error.IncompleteStream,
        ai.transport.HttpError.IdleTimeout,
    }) |err| {
        const detail = classify(err);
        try testing.expectEqual(Class.transport, detail.class);
        try testing.expect(detail.code == .network or detail.code == .timeout);
    }
}

test "an unlisted error reports an internal failure that names the error, never a provider failure" {
    const detail = classify(error.SomethingElse);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.internal, detail.code);
    const got = outcome(testing.allocator, error.SomethingElse, &.{});
    try testing.expectEqualStrings("SomethingElse", got.detail.?);
    try testing.expectEqual(@as(?u16, null), got.status);
}

test "an error event inside a 200 stream reports its class and its detail line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const info: ai.transport.AttemptInfo = .{ .body = "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"}}}" };
    const got = outcome(arena.allocator(), ai.transport.HttpError.ContextOverflow, &info);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, got.code);
    try testing.expectEqualStrings("too long (context_length_exceeded)", got.detail.?);
    // A provider answer explains itself, so the detail never falls back to the error name.
    const bare = outcome(arena.allocator(), ai.transport.HttpError.ProviderFailed, &.{});
    try testing.expectEqual(proto.enums.RunErrorCode.provider, bare.code);
    try testing.expectEqual(@as(?[]const u8, null), bare.detail);
}

test "an engine error keeps its own code, which the library cannot name" {
    try testing.expectEqual(proto.enums.RunErrorCode.unsupported_reasoning, classify(error.UnsupportedReasoning).code);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, classify(error.TurnTooLarge).code);
    try testing.expectEqual(proto.enums.RunErrorCode.unknown_model, classify(error.UnknownModel).code);
}

test "the library request bound reports context overflow" {
    const detail = classify(error.RequestTooLarge);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, detail.code);
    try testing.expectEqualStrings("the request exceeds the library size limit", detail.message);
}

test "an extension that stops a request reports a runtime failure" {
    const detail = classify(error.HookBlocked);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.runtime, detail.code);
}

test "a blob the store cannot resolve after admission reports a runtime failure, not a provider one" {
    const detail = classify(error.UnresolvedBlob);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.runtime, detail.code);
}

test "an oversized prompt reports a permanent runtime failure" {
    const detail = classify(error.PromptTooLarge);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.runtime, detail.code);
    try testing.expectEqualStrings("the system prompt exceeds the protocol string limit", detail.message);
}
