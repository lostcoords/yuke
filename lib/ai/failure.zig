//! One row per provider error: how a repeat behaves, and what the caller can be told.

const std = @import("std");
const http = @import("transport/http.zig");
const answer = @import("answer.zig");

/// Build the bounded detail line of one provider answer.
pub const detailText = answer.detailText;

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
    connection_lost,
    malformed_stream,
    stream_too_large,
    trust_store_failed,
    auth_rejected,
    permission_denied,
    quota_exhausted,
    bad_status,
    context_overflow,
    provider_failed,
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
            .connection_lost => "the provider connection ended",
            .malformed_stream => "the provider stream was malformed",
            .stream_too_large => "the provider stream exceeds the library size limit",
            .trust_store_failed => "the system certificate store could not be read",
            .auth_rejected => "the provider rejected the API key",
            .permission_denied => "the provider denied permission for this request",
            .quota_exhausted => "the provider account quota is exhausted",
            .bad_status => "the provider returned an unexpected status",
            .context_overflow => "the provider reports that the input exceeds the model context window",
            .provider_failed => "the provider reported an error",
            .bad_url => "the provider endpoint URL is invalid",
            .invalid_headers => "the provider request headers are invalid",
            .redirect_refused => "the provider attempted a redirect",
            .out_of_memory => "the caller ran out of memory",
            .request_too_large => "the request exceeds the library size limit",
            .malformed_selector => "the model selector is malformed",
            .unknown_provider => "the catalog holds no provider with that name",
            .unknown_model => "the catalog holds no model with that name",
            .unknown => "an internal error stopped the request",
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
        http.Error.StatusTimeout => .{ .class = .answered_transient, .reason = .stream_timeout },

        // The transport owns the `std` error names, so this table reads its closed set only.
        http.Error.IdleTimeout => .{ .class = .transport, .reason = .stream_timeout },
        http.Error.ConnectFailed => .{ .class = .transport, .reason = .connect_failed },
        http.Error.ConnectionLost => .{ .class = .transport, .reason = .connection_lost },
        http.Error.DnsFailed => .{ .class = .transport, .reason = .dns_failed },
        // A stream without its terminal event is a truncation, not a malformed stream.
        error.IncompleteStream => .{ .class = .transport, .reason = .stream_truncated },

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
        http.Error.ContextOverflow => .{ .class = .permanent, .reason = .context_overflow },
        http.Error.ProviderFailed => .{ .class = .permanent, .reason = .provider_failed },
        http.Error.BadUrl => .{ .class = .permanent, .reason = .bad_url },
        http.Error.InvalidHeaders => .{ .class = .permanent, .reason = .invalid_headers },
        http.Error.RedirectRefused => .{ .class = .permanent, .reason = .redirect_refused },
        http.Error.CertificateBundleLoadFailure => .{ .class = .permanent, .reason = .trust_store_failed },
        // A parse error never repeats. Keep it apart from a truncation.
        http.Error.MalformedResponse,
        error.Protocol,
        => .{ .class = .permanent, .reason = .malformed_stream },
        error.LineTooLong,
        error.EventTooLarge,
        error.ResponseTooLarge,
        => .{ .class = .permanent, .reason = .stream_too_large },
        else => .{ .class = .permanent, .reason = .unknown },
    };
}

const testing = std.testing;

test "every transport class names its exact connection reason, never a provider answer" {
    // A retryable connection fault must never reach a caller as a permanent provider failure.
    for ([_]struct { anyerror, Reason }{
        .{ http.Error.ConnectFailed, .connect_failed },
        .{ http.Error.ConnectionLost, .connection_lost },
        .{ http.Error.DnsFailed, .dns_failed },
        .{ error.IncompleteStream, .stream_truncated },
        .{ http.Error.IdleTimeout, .stream_timeout },
    }) |case| {
        const got = classify(case[0]);
        try testing.expectEqual(Class.transport, got.class);
        try testing.expectEqual(case[1], got.reason);
    }
}

test "every transport error names a reason, so none reaches a caller as unknown" {
    // The transport owns a closed set. An unlisted member would read as a bare provider failure.
    inline for (@typeInfo(http.Error).error_set.?) |member| {
        const got = classify(@field(http.Error, member.name));
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
