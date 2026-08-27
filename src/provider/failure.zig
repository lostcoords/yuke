//! One row per provider error: the retry class, the wire code, and one model-visible sentence.

const std = @import("std");
const wire = @import("wire");
const http = @import("transport/http.zig");

/// How an error class behaves for a repeat.
pub const Class = enum {
    /// The provider answered and named a temporary condition. The request certainly arrived.
    answered_transient,
    /// The connection failed. The delivery gate decides whether a repeat is safe.
    transport,
    /// The error can never succeed.
    permanent,
};

/// One error row. The wire message exposes no internal error name.
pub const Detail = struct {
    class: Class,
    code: wire.enums.RunErrorCode,
    message: []const u8,
};

/// Classify one provider error. An unlisted error is permanent and reports a generic failure.
pub fn classify(err: anyerror) Detail {
    return switch (err) {
        http.Error.RateLimited => .{ .class = .answered_transient, .code = .rate_limited, .message = "the provider rate limit was reached" },
        http.Error.ServerError => .{ .class = .answered_transient, .code = .provider, .message = "the provider returned a server error" },
        http.Error.Timeout => .{ .class = .answered_transient, .code = .timeout, .message = "the provider stream timed out" },

        http.Error.IdleTimeout => .{ .class = .transport, .code = .timeout, .message = "the provider stream timed out" },
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.EndOfStream,
        => .{ .class = .transport, .code = .network, .message = "the provider connection failed" },
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.HostLacksNetworkAddresses,
        => .{ .class = .transport, .code = .network, .message = "the daemon could not resolve the provider host" },
        // A stream without its terminal event is a truncation, not a malformed stream.
        error.IncompleteStream,
        error.HttpChunkTruncated,
        => .{ .class = .transport, .code = .network, .message = "the provider stream ended early" },

        error.OutOfMemory => .{ .class = .permanent, .code = .internal, .message = "the daemon ran out of memory" },
        error.UnknownModel => .{ .class = .permanent, .code = .unknown_model, .message = "the model is not configured" },
        http.Error.AuthFailed => .{ .class = .permanent, .code = .auth, .message = "the provider rejected the API key" },
        http.Error.PermissionDenied => .{ .class = .permanent, .code = .auth, .message = "the provider denied permission for this request" },
        // A rate limit must PROVE itself, so an unreadable 429 never repeats.
        http.Error.RateLimitUnknown => .{ .class = .permanent, .code = .rate_limited, .message = "the provider returned a 429 the daemon could not classify" },
        http.Error.QuotaExhausted => .{ .class = .permanent, .code = .quota_exhausted, .message = "the provider account quota is exhausted" },
        http.Error.BadStatus => .{ .class = .permanent, .code = .provider, .message = "the provider returned an unexpected status" },
        http.Error.BadUrl => .{ .class = .permanent, .code = .provider, .message = "the provider endpoint URL is invalid" },
        http.Error.RedirectRefused => .{ .class = .permanent, .code = .protocol, .message = "the provider attempted a redirect" },
        // A parse error never repeats. Keep it apart from a truncation.
        error.Protocol,
        error.InvalidCharacter,
        error.HttpChunkInvalid,
        => .{ .class = .permanent, .code = .protocol, .message = "the provider stream was malformed" },
        else => .{ .class = .permanent, .code = .provider, .message = "the provider request failed" },
    };
}

const testing = std.testing;

test "every transport class reports a network or timeout code" {
    // A retryable connection fault must never reach the client as a generic provider failure.
    for ([_]anyerror{
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.HostLacksNetworkAddresses,
        error.EndOfStream,
        error.IncompleteStream,
        error.HttpChunkTruncated,
        http.Error.IdleTimeout,
    }) |err| {
        const detail = classify(err);
        try testing.expectEqual(Class.transport, detail.class);
        try testing.expect(detail.code == .network or detail.code == .timeout);
    }
}

test "an unlisted error reports a generic provider failure" {
    const detail = classify(error.SomethingElse);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(wire.enums.RunErrorCode.provider, detail.code);
}
