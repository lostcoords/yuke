//! One row per provider error: how a repeat behaves, and what the caller can be told.

const std = @import("std");
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

/// Why one attempt failed. A caller projects this onto its own error vocabulary.
pub const Reason = enum {
    rate_limited,
    rate_limit_unknown,
    server_error,
    stream_timeout,
    connect_failed,
    dns_failed,
    stream_truncated,
    malformed_stream,
    auth_rejected,
    permission_denied,
    quota_exhausted,
    bad_status,
    bad_url,
    invalid_headers,
    redirect_refused,
    out_of_memory,
    request_too_large,
    malformed_selector,
    unknown_provider,
    unknown_model,
    unknown,

    /// One sentence for the caller. It names no internal error and no credential.
    pub fn message(self: Reason) []const u8 {
        return switch (self) {
            .rate_limited => "the provider rate limit was reached",
            .rate_limit_unknown => "the provider returned a 429 the caller could not classify",
            .server_error => "the provider returned a server error",
            .stream_timeout => "the provider stream timed out",
            .connect_failed => "the provider connection failed",
            .dns_failed => "the provider host did not resolve",
            .stream_truncated => "the provider stream ended early",
            .malformed_stream => "the provider stream was malformed",
            .auth_rejected => "the provider rejected the API key",
            .permission_denied => "the provider denied permission for this request",
            .quota_exhausted => "the provider account quota is exhausted",
            .bad_status => "the provider returned an unexpected status",
            .bad_url => "the provider endpoint URL is invalid",
            .invalid_headers => "the provider request headers are invalid",
            .redirect_refused => "the provider attempted a redirect",
            .out_of_memory => "the caller ran out of memory",
            .request_too_large => "the request exceeds the library size limit",
            .malformed_selector => "the model selector is malformed",
            .unknown_provider => "the catalog holds no provider with that name",
            .unknown_model => "the catalog holds no model with that name",
            .unknown => "the provider request failed",
        };
    }
};

pub const Failure = struct {
    class: Class,
    reason: Reason,
};

/// Classify one provider error. An unlisted error is permanent, because a repeat must be earned.
pub fn classify(err: anyerror) Failure {
    return switch (err) {
        http.Error.RateLimited => .{ .class = .answered_transient, .reason = .rate_limited },
        http.Error.ServerError => .{ .class = .answered_transient, .reason = .server_error },
        http.Error.Timeout => .{ .class = .answered_transient, .reason = .stream_timeout },

        http.Error.IdleTimeout => .{ .class = .transport, .reason = .stream_timeout },
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.EndOfStream,
        => .{ .class = .transport, .reason = .connect_failed },
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.HostLacksNetworkAddresses,
        => .{ .class = .transport, .reason = .dns_failed },
        // A stream without its terminal event is a truncation, not a malformed stream.
        error.IncompleteStream,
        error.HttpChunkTruncated,
        => .{ .class = .transport, .reason = .stream_truncated },

        error.OutOfMemory => .{ .class = .permanent, .reason = .out_of_memory },
        error.RequestTooLarge => .{ .class = .permanent, .reason = .request_too_large },
        // `catalog.resolve` raises these, so the library must be able to describe them.
        error.MalformedSelector => .{ .class = .permanent, .reason = .malformed_selector },
        error.UnknownProvider => .{ .class = .permanent, .reason = .unknown_provider },
        error.UnknownModel => .{ .class = .permanent, .reason = .unknown_model },
        http.Error.AuthFailed => .{ .class = .permanent, .reason = .auth_rejected },
        http.Error.PermissionDenied => .{ .class = .permanent, .reason = .permission_denied },
        // A rate limit must PROVE itself, so an unreadable 429 never repeats.
        http.Error.RateLimitUnknown => .{ .class = .permanent, .reason = .rate_limit_unknown },
        http.Error.QuotaExhausted => .{ .class = .permanent, .reason = .quota_exhausted },
        http.Error.BadStatus => .{ .class = .permanent, .reason = .bad_status },
        http.Error.BadUrl => .{ .class = .permanent, .reason = .bad_url },
        http.Error.InvalidHeaders => .{ .class = .permanent, .reason = .invalid_headers },
        http.Error.RedirectRefused => .{ .class = .permanent, .reason = .redirect_refused },
        // A parse error never repeats. Keep it apart from a truncation.
        error.Protocol,
        error.HttpChunkInvalid,
        => .{ .class = .permanent, .reason = .malformed_stream },
        else => .{ .class = .permanent, .reason = .unknown },
    };
}

const testing = std.testing;

test "every transport class names a connection reason, never a provider answer" {
    // A retryable connection fault must never reach a caller as a permanent provider failure.
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
        const got = classify(err);
        try testing.expectEqual(Class.transport, got.class);
        try testing.expect(got.reason != .unknown);
    }
}

test "an unlisted error is permanent and generic" {
    const got = classify(error.SomethingElse);
    try testing.expectEqual(Class.permanent, got.class);
    try testing.expectEqual(Reason.unknown, got.reason);
}

test "every reason states a sentence" {
    // A blank sentence would reach a user as an empty error, so each arm must answer.
    inline for (std.meta.tags(Reason)) |reason| try testing.expect(reason.message().len != 0);
}
