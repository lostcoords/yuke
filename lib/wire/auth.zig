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
    flow: enums.AuthFlow,
};

/// This result identifies the mechanism that the daemon started for `auth.login`.
pub const AuthLoginResult = union(enum) {
    browser: AuthLoginResultBrowser,
    device_code: AuthLoginResultDeviceCode,

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

/// The daemon returns these browser authorization details only to the connection that sent the request.
pub const AuthLoginResultBrowser = struct {
    login_id: ids.LoginId,
    auth_url: []const u8,
};

/// The daemon returns these device authorization details only to the connection that sent the request.
pub const AuthLoginResultDeviceCode = struct {
    login_id: ids.LoginId,
    verification_url: []const u8,
    user_code: []const u8,
};

/// This type identifies one daemon-owned login attempt. It contains no OAuth secret.
pub const AuthLoginSummary = struct {
    login_id: ids.LoginId,
    flow: enums.AuthFlow,
};

/// These are the parameters for `auth.remove`. It removes a local credential; OAuth waits for stage 10.
pub const AuthRemoveParams = struct {
    provider_id: ids.ProviderId,
};

/// Public authentication state and capabilities for one provider.
pub const AuthProvider = struct {
    provider_id: ids.ProviderId,
    credential_kind: ?enums.AuthCredentialKind = null,
    login_flows: []const enums.AuthFlow,
    pending_login: ?AuthLoginSummary = null,
};

/// These are write-only parameters for `auth.set_api_key`. The wire state never returns or retains the key.
pub const AuthSetApiKeyParams = struct {
    provider_id: ids.ProviderId,
    api_key: []const u8,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "login result union round-trips a device_code arm" {
    const json =
        \\{"type":"device_code","login_id":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","verification_url":"https://example.com/device","user_code":"ABCD-1234"}
    ;
    const parsed = try std.json.parseFromSlice(AuthLoginResult, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .device_code);
    try testing.expectEqualStrings("ABCD-1234", parsed.value.device_code.user_code);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
