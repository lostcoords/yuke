//! Auth protocol types: providers, login flows, and their outcomes.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");

/// Params for `auth.cancel_login`.
pub const AuthCancelLoginParams = struct {
    login_id: ids.LoginId,
};

/// Payload for `auth.changed`.
pub const AuthChangedData = struct {
    provider: AuthProvider,
};

/// Result of `auth.list`.
pub const AuthListResult = struct {
    providers: []const AuthProvider,
};

/// Payload for `auth.login_finished`.
pub const AuthLoginFinishedData = struct {
    login_id: ids.LoginId,
    provider_id: ids.ProviderId,
    outcome: AuthLoginOutcome,
};

/// Terminal outcome for a daemon-owned login attempt.
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

/// Login was explicitly canceled.
pub const AuthLoginOutcomeCanceled = struct {};

/// Login failed without changing durable credentials.
pub const AuthLoginOutcomeFailed = struct {
    message: []const u8,
};

/// Login completed successfully and credentials were durably stored.
pub const AuthLoginOutcomeSucceeded = struct {};

/// Params for `auth.login`.
pub const AuthLoginParams = struct {
    provider_id: ids.ProviderId,
    flow: enums.AuthFlow,
};

/// Result of `auth.login`, tagged by the mechanism actually started.
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

/// Browser authorization details returned only to the requesting connection.
pub const AuthLoginResultBrowser = struct {
    login_id: ids.LoginId,
    auth_url: []const u8,
};

/// Device authorization details returned only to the requesting connection.
pub const AuthLoginResultDeviceCode = struct {
    login_id: ids.LoginId,
    verification_url: []const u8,
    user_code: []const u8,
};

/// Public locator for one daemon-owned login attempt. It contains no OAuth secret.
pub const AuthLoginSummary = struct {
    login_id: ids.LoginId,
    flow: enums.AuthFlow,
};

/// Params for `auth.logout`.
pub const AuthLogoutParams = struct {
    provider_id: ids.ProviderId,
};

/// Public authentication state and capabilities for one provider.
pub const AuthProvider = struct {
    provider_id: ids.ProviderId,
    credential_kind: ?enums.AuthCredentialKind = null,
    restart_required: bool,
    login_flows: []const enums.AuthFlow,
    pending_login: ?AuthLoginSummary = null,
};

/// Write-only params for `auth.set_api_key`. The key is never returned or retained by wire state.
pub const AuthSetApiKeyParams = struct {
    provider_id: ids.ProviderId,
    api_key: []const u8,
};

/// Result of staging an API-key replacement.
pub const AuthSetApiKeyResult = struct {
    restart_required: bool,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "login result union round-trips a device_code arm" {
    const json =
        \\{"type":"device_code","login_id":"0123456789abcdef0123456789abcdef","verification_url":"https://example.com/device","user_code":"ABCD-1234"}
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

test "provider decodes null requiredNullable fields" {
    const json =
        \\{"provider_id":"anthropic","credential_kind":null,"restart_required":false,"login_flows":["browser"],"pending_login":null}
    ;
    const parsed = try std.json.parseFromSlice(AuthProvider, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.credential_kind == null);
    try testing.expect(parsed.value.pending_login == null);
    try testing.expectEqual(@as(usize, 1), parsed.value.login_flows.len);
    try testing.expectEqual(enums.AuthFlow.browser, parsed.value.login_flows[0]);
}
