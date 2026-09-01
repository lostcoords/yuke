//! Auth types for providers, login flows, and outcomes.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// These are the parameters for `auth.cancel_login`.
pub const AuthCancelLoginParams = struct {
    login_id: ids.LoginId,
};

/// This payload describes `auth.changed`.
pub const AuthChangedData = struct {
    provider: AuthProvider,
};

/// This result describes `auth.list`.
pub const AuthListResult = struct {
    providers: []const AuthProvider,
};

/// This payload describes `auth.login_finished`.
pub const AuthLoginFinishedData = struct {
    login_id: ids.LoginId,
    provider_id: ids.ProviderId,
    outcome: AuthLoginOutcome,
};

/// This union reports the terminal outcome of a daemon-owned login attempt.
pub const AuthLoginOutcome = union(enum) {
    succeeded: AuthLoginOutcomeSucceeded,
    canceled: AuthLoginOutcomeCanceled,
    failed: AuthLoginOutcomeFailed,

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

/// The login was explicitly canceled.
pub const AuthLoginOutcomeCanceled = struct {};

/// The login failed without changing durable credentials.
pub const AuthLoginOutcomeFailed = struct {
    message: []const u8,
};

/// The daemon completed login and durably stored the credentials.
pub const AuthLoginOutcomeSucceeded = struct {};

/// These are the parameters for `auth.login`.
pub const AuthLoginParams = struct {
    provider_id: ids.ProviderId,
};

/// The daemon returns these device authorization details only to the connection that sent the request.
pub const AuthLoginResult = struct {
    login_id: ids.LoginId,
    verification_url: []const u8,
    user_code: []const u8,
};

/// These parameters select the local credential to remove. OAuth waits for stage 10.
pub const AuthRemoveParams = struct {
    provider_id: ids.ProviderId,
};

/// Public authentication state and capabilities for one provider.
pub const AuthProvider = struct {
    provider_id: ids.ProviderId,
    credential_kind: ?enums.AuthCredentialKind = null,
    can_login: bool,
};

/// These `auth.set_api_key` parameters carry a key that the wire never returns.
pub const AuthSetApiKeyParams = struct {
    provider_id: ids.ProviderId,
    api_key: []const u8,
};
