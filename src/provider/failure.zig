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
        error.TurnTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the turn is larger than the model context window" },
        error.UnsupportedReasoning => .{ .class = .permanent, .code = .unsupported_reasoning, .message = "the model does not support this reasoning level" },
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
        .connect_failed, .dns_failed, .stream_truncated => .network,
        .malformed_stream, .redirect_refused => .protocol,
        .auth_rejected, .permission_denied => .auth,
        .quota_exhausted => .quota_exhausted,
        .out_of_memory => .internal,
        .request_too_large => .context_overflow,
        .malformed_selector, .unknown_provider, .unknown_model => .unknown_model,
        .server_error, .bad_status, .bad_url, .invalid_headers, .unknown => .provider,
    };
}

const testing = std.testing;

test "every transport class reports a network or timeout code" {
    // A retryable connection fault must never reach the client as a generic provider failure.
    for ([_]anyerror{
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.NameServerFailure,
        error.IncompleteStream,
        ai.http_transport.Error.IdleTimeout,
    }) |err| {
        const detail = classify(err);
        try testing.expectEqual(Class.transport, detail.class);
        try testing.expect(detail.code == .network or detail.code == .timeout);
    }
}

test "an unlisted error reports a generic provider failure" {
    const detail = classify(error.SomethingElse);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.provider, detail.code);
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
