//! Auth types for providers, login flows, and outcomes.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// These are the parameters for `auth.cancel_login`.
pub const AuthCancelLoginParams = struct {
    login_id: ids.LoginId,
};

/// This payload describes `auth.login_finished`.
pub const AuthLoginFinishedData = struct {
    login_id: ids.LoginId,
    provider_id: ids.ProviderId,
    outcome: AuthLoginOutcome,
};

/// This union reports the terminal outcome of an engine-owned login attempt.
pub const AuthLoginOutcome = union(enum) {
    succeeded: AuthLoginOutcomeSucceeded,
    canceled: AuthLoginOutcomeCanceled,
    failed: AuthLoginOutcomeFailed,

    /// Decode a tagged wire union from JSON.
    pub const jsonParse = tagged.Codec(@This()).jsonParse;
    pub const jsonParseFromValue = tagged.Codec(@This()).jsonParseFromValue;
    pub const jsonStringify = tagged.Codec(@This()).jsonStringify;
};

/// The login was explicitly canceled.
pub const AuthLoginOutcomeCanceled = struct {};

/// The login failed without changing durable credentials.
pub const AuthLoginOutcomeFailed = struct {
    message: []const u8,
};

/// The engine completed login and durably stored the credentials.
pub const AuthLoginOutcomeSucceeded = struct {};

/// These are the parameters for `auth.login`.
pub const AuthLoginParams = struct {
    provider_id: ids.ProviderId,
};

/// The engine returns these device authorization details only to the connection that sent the request.
pub const AuthLoginResult = struct {
    login_id: ids.LoginId,
    verification_url: []const u8,
    user_code: []const u8,
};

/// These parameters select the local credential to remove, an API key or a grant.
pub const AuthRemoveParams = struct {
    provider_id: ids.ProviderId,
};

/// These `auth.set_api_key` parameters carry a key that the wire never returns.
pub const AuthSetApiKeyParams = struct {
    provider_id: ids.ProviderId,
    api_key: []const u8,
};
