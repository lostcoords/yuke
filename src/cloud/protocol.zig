//! Encode and decode the yuke-cloud device-code API. This file performs no input and no output.
//! Every decoder treats the body as peer input: it returns an error and never asserts.

const std = @import("std");
const poller = @import("../net/poller.zig");

/// Name the principals that one grant creates. The value goes on the wire.
pub const Intent = enum { daemon, client, both };

/// Name the credential shape of a client session. The value goes on the wire.
pub const SessionKind = enum { cli, token };

/// The device credential prefix that the control plane mints.
pub const device_prefix = "yk_dev_";

/// The session credential prefix that the control plane mints.
pub const session_prefix = "yk_sess_";

const max_code_bytes = 512;
const max_id_bytes = 256;
const max_uri_bytes = 2048;
const max_user_code_bytes = 64;
const max_detail_bytes = 1024;

/// One day. It bounds a grant lifetime that the server reports.
const max_expires_in_s = 24 * 60 * 60;

/// One hour. It bounds a poll interval that the server reports.
const max_interval_s = 60 * 60;

pub const Error = error{InvalidResponse};

/// The fields of a device-code start request.
pub const StartRequest = struct {
    name: []const u8,
    platform: []const u8,
    /// The base64 X25519 public key. A client grant carries no key and the encoder omits it.
    static_public_key: ?[]const u8,
    intent: Intent,
    session_kind: SessionKind,
};

const StartBody = struct {
    name: []const u8,
    platform: []const u8,
    static_public_key: ?[]const u8 = null,
    intent: []const u8,
    session_kind: []const u8,
};

const PollBody = struct { device_code: []const u8 };

const stringify_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// Encode the body of `POST /api/v1/device_codes`. The caller frees the result.
pub fn encodeStart(gpa: std.mem.Allocator, req: StartRequest) ![]u8 {
    std.debug.assert(req.intent != .client or req.static_public_key == null); // A client grant pins no key.

    return encodeBody(gpa, StartBody{
        .name = req.name,
        .platform = req.platform,
        .static_public_key = req.static_public_key,
        .intent = @tagName(req.intent),
        .session_kind = @tagName(req.session_kind),
    });
}

/// Encode the body of `POST /api/v1/device_codes/token`. The caller frees the result.
pub fn encodePoll(gpa: std.mem.Allocator, device_code: []const u8) ![]u8 {
    std.debug.assert(device_code.len != 0); // The caller holds a decoded start response.

    return encodeBody(gpa, PollBody{ .device_code = device_code });
}

fn encodeBody(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(value, stringify_options, &out.writer);
    return out.toOwnedSlice();
}

/// The 201 response to a device-code start. Every slice borrows the decode arena.
pub const Start = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: []const u8,
    expires_in_s: u64,
    interval_s: u64,
};

const StartWire = struct {
    device_code: []const u8 = "",
    user_code: []const u8 = "",
    verification_uri: []const u8 = "",
    verification_uri_complete: []const u8 = "",
    expires_in: i64 = 0,
    interval: i64 = 0,
};

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Decode a device-code start response. The result borrows `arena`.
pub fn decodeStart(arena: std.mem.Allocator, body: []const u8) Error!Start {
    const wire = std.json.parseFromSliceLeaky(StartWire, arena, body, parse_options) catch return error.InvalidResponse;

    const expires_in_s = positive(wire.expires_in, max_expires_in_s) orelse return error.InvalidResponse;
    const interval_s = positive(wire.interval, max_interval_s) orelse return error.InvalidResponse;

    const out: Start = .{
        .device_code = wire.device_code,
        .user_code = wire.user_code,
        .verification_uri = wire.verification_uri,
        // The complete URI is a convenience. Fall back to the plain URI when the server omits it.
        .verification_uri_complete = if (wire.verification_uri_complete.len != 0)
            wire.verification_uri_complete
        else
            wire.verification_uri,
        .expires_in_s = expires_in_s,
        .interval_s = interval_s,
    };

    if (!bounded(out.device_code, max_code_bytes)) return error.InvalidResponse;
    if (!bounded(out.user_code, max_user_code_bytes)) return error.InvalidResponse;
    if (!bounded(out.verification_uri, max_uri_bytes)) return error.InvalidResponse;
    if (!bounded(out.verification_uri_complete, max_uri_bytes)) return error.InvalidResponse;
    return out;
}

/// The 201 response to an approved poll. An absent field stays empty. Every slice borrows the decode arena.
pub const Credential = struct {
    device_id: []const u8 = "",
    credential: []const u8 = "",
    relay_url: []const u8 = "",
    session_id: []const u8 = "",
    session_credential: []const u8 = "",

    /// The credential that a client session presents. A client grant returns it in `credential`.
    pub fn sessionCredential(self: Credential) []const u8 {
        return if (self.session_credential.len != 0) self.session_credential else self.credential;
    }
};

/// Decode an approved poll response and check it against `intent`. The result borrows `arena`.
pub fn decodeCredential(arena: std.mem.Allocator, body: []const u8, intent: Intent) Error!Credential {
    const out = std.json.parseFromSliceLeaky(Credential, arena, body, parse_options) catch return error.InvalidResponse;

    // An identifier is empty when the grant does not create that principal. Only cap the length here.
    if (!bounded(out.relay_url, max_uri_bytes)) return error.InvalidResponse;
    if (out.device_id.len > max_id_bytes or out.session_id.len > max_id_bytes) return error.InvalidResponse;

    // A daemon grant returns the device credential. A client grant returns the session credential
    // in the same field, so only a `both` grant carries the second one.
    switch (intent) {
        .daemon => {
            if (out.device_id.len == 0) return error.InvalidResponse;
            if (!credentialValid(out.credential, device_prefix)) return error.InvalidResponse;
        },
        .client => {
            if (out.session_id.len == 0) return error.InvalidResponse;
            if (!credentialValid(out.credential, session_prefix)) return error.InvalidResponse;
        },
        .both => {
            if (out.device_id.len == 0 or out.session_id.len == 0) return error.InvalidResponse;
            if (!credentialValid(out.credential, device_prefix)) return error.InvalidResponse;
            if (!credentialValid(out.session_credential, session_prefix)) return error.InvalidResponse;
        },
    }
    return out;
}

/// The stable machine-readable value of an RFC 9457 problem document.
/// An unlisted value decodes to `unknown`, so a new server code never takes a known path.
pub const Code = enum {
    authorization_pending,
    slow_down,
    rate_limited,
    access_denied,
    plan_limit,
    email_unverified,
    invalid_grant,
    expired_token,
    conflict,
    invalid,
    unknown,
};

const code_names = std.StaticStringMap(Code).initComptime(.{
    .{ "AUTHORIZATION_PENDING", .authorization_pending },
    .{ "SLOW_DOWN", .slow_down },
    .{ "RATE_LIMITED", .rate_limited },
    .{ "ACCESS_DENIED", .access_denied },
    .{ "PLAN_LIMIT", .plan_limit },
    .{ "EMAIL_UNVERIFIED", .email_unverified },
    .{ "INVALID_GRANT", .invalid_grant },
    .{ "EXPIRED_TOKEN", .expired_token },
    .{ "CONFLICT", .conflict },
    .{ "INVALID", .invalid },
});

/// One decoded problem document. `detail` is human text and never selects behavior.
pub const Problem = struct {
    code: Code = .unknown,
    detail: []const u8 = "",
    /// The poll interval in seconds that a problem reports while it waits for approval.
    interval_s: ?u64 = null,
};

const ProblemWire = struct {
    code: []const u8 = "",
    detail: []const u8 = "",
    interval: ?i64 = null,
};

/// Decode a problem document. A body that is not a problem document gives an unknown problem,
/// because the status alone already selects a failure.
pub fn decodeProblem(arena: std.mem.Allocator, body: []const u8) Problem {
    const wire = std.json.parseFromSliceLeaky(ProblemWire, arena, body, parse_options) catch return .{};

    return .{
        .code = code_names.get(wire.code) orelse .unknown,
        .detail = if (wire.detail.len <= max_detail_bytes) wire.detail else wire.detail[0..max_detail_bytes],
        .interval_s = if (wire.interval) |raw| positive(raw, max_interval_s) else null,
    };
}

fn bounded(value: []const u8, max: usize) bool {
    return value.len != 0 and value.len <= max;
}

fn credentialValid(value: []const u8, prefix: []const u8) bool {
    return bounded(value, max_code_bytes) and std.mem.startsWith(u8, value, prefix);
}

/// Return `value` when it is positive and within `max`. A JSON number outside the range gives null.
fn positive(value: i64, max: u64) ?u64 {
    if (value <= 0) return null;
    const out: u64 = @intCast(value);
    return if (out <= max) out else null;
}

const testing = std.testing;

test "encodeStart omits the key for a client grant" {
    const body = try encodeStart(testing.allocator, .{
        .name = "box",
        .platform = "macos",
        .static_public_key = null,
        .intent = .client,
        .session_kind = .token,
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        \\{"name":"box","platform":"macos","intent":"client","session_kind":"token"}
    , body);
}

test "encodeStart carries the key for a daemon grant" {
    const body = try encodeStart(testing.allocator, .{
        .name = "box",
        .platform = "linux",
        .static_public_key = "QUJD",
        .intent = .daemon,
        .session_kind = .cli,
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        \\{"name":"box","platform":"linux","static_public_key":"QUJD","intent":"daemon","session_kind":"cli"}
    , body);
}

test "encodePoll carries only the device code" {
    const body = try encodePoll(testing.allocator, "secret-handle");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        \\{"device_code":"secret-handle"}
    , body);
}

fn testArena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "decodeStart reads a complete response" {
    var arena = testArena();
    defer arena.deinit();
    const out = try decodeStart(arena.allocator(),
        \\{"device_code":"dc","user_code":"BCDF-GHJK","verification_uri":"https://p/enroll",
        \\ "verification_uri_complete":"https://p/enroll?code=BCDF-GHJK","expires_in":900,"interval":5}
    );
    try testing.expectEqualStrings("dc", out.device_code);
    try testing.expectEqualStrings("BCDF-GHJK", out.user_code);
    try testing.expectEqual(@as(u64, 900), out.expires_in_s);
    try testing.expectEqual(@as(u64, 5), out.interval_s);
}

test "decodeStart falls back to the plain verification uri" {
    var arena = testArena();
    defer arena.deinit();
    const out = try decodeStart(arena.allocator(),
        \\{"device_code":"dc","user_code":"BCDF-GHJK","verification_uri":"https://p/enroll","expires_in":900,"interval":5}
    );
    try testing.expectEqualStrings("https://p/enroll", out.verification_uri_complete);
}

test "decodeStart rejects a missing field and a bad number" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidResponse, decodeStart(a,
        \\{"user_code":"BCDF-GHJK","verification_uri":"https://p","expires_in":900,"interval":5}
    ));
    try testing.expectError(error.InvalidResponse, decodeStart(a,
        \\{"device_code":"dc","user_code":"C","verification_uri":"https://p","expires_in":0,"interval":5}
    ));
    try testing.expectError(error.InvalidResponse, decodeStart(a,
        \\{"device_code":"dc","user_code":"C","verification_uri":"https://p","expires_in":900,"interval":-1}
    ));
    try testing.expectError(error.InvalidResponse, decodeStart(a, "not json"));
}

test "decodeCredential checks each intent" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const daemon = try decodeCredential(a,
        \\{"device_id":"d1","credential":"yk_dev_abc","relay_url":"wss://r"}
    , .daemon);
    try testing.expectEqualStrings("d1", daemon.device_id);

    const client = try decodeCredential(a,
        \\{"session_id":"s1","credential":"yk_sess_abc","relay_url":"wss://r"}
    , .client);
    try testing.expectEqualStrings("yk_sess_abc", client.sessionCredential());

    const both = try decodeCredential(a,
        \\{"device_id":"d1","credential":"yk_dev_abc","session_id":"s1","session_credential":"yk_sess_abc","relay_url":"wss://r"}
    , .both);
    try testing.expectEqualStrings("yk_dev_abc", both.credential);
    try testing.expectEqualStrings("yk_sess_abc", both.sessionCredential());
}

test "decodeCredential rejects a wrong prefix and a missing principal" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidResponse, decodeCredential(a,
        \\{"device_id":"d1","credential":"yk_sess_abc","relay_url":"wss://r"}
    , .daemon));
    try testing.expectError(error.InvalidResponse, decodeCredential(a,
        \\{"credential":"yk_dev_abc","relay_url":"wss://r"}
    , .daemon));
    try testing.expectError(error.InvalidResponse, decodeCredential(a,
        \\{"device_id":"d1","credential":"yk_dev_abc","session_id":"s1","relay_url":"wss://r"}
    , .both));
}

test "decodeProblem maps a known code and keeps the interval" {
    var arena = testArena();
    defer arena.deinit();
    const out = decodeProblem(arena.allocator(),
        \\{"type":"about:blank","title":"Precondition Required","status":428,
        \\ "code":"AUTHORIZATION_PENDING","detail":"Waiting for approval.","interval":5}
    );
    try testing.expectEqual(Code.authorization_pending, out.code);
    try testing.expectEqualStrings("Waiting for approval.", out.detail);
    try testing.expectEqual(@as(u64, 5), out.interval_s.?);
}

test "decodeProblem degrades an unknown code and a bad body" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Code.unknown, decodeProblem(a,
        \\{"code":"TEAPOT","detail":"new"}
    ).code);
    try testing.expectEqual(Code.unknown, decodeProblem(a, "<html>").code);
    try testing.expect(decodeProblem(a,
        \\{"code":"SLOW_DOWN","interval":-2}
    ).interval_s == null);
}

/// Map one HTTP status and problem document onto a reply.
/// An unknown code never takes a known path: it either retries on a retry status or stops.
pub fn classify(status: u16, problem: Problem) poller.Reply {
    if (status >= 200 and status < 300) return .approved;
    if (status >= 500) return .unavailable;

    return switch (status) {
        428 => .{ .pending = problem.interval_s },
        429 => if (problem.code == .slow_down) .{ .slow_down = problem.interval_s } else .retryable,
        409 => .retryable,
        else => .terminal,
    };
}

test "classify maps every documented status" {
    try testing.expect(classify(201, .{}) == .approved);
    try testing.expect(classify(200, .{}) == .approved);
    try testing.expect(classify(428, .{ .code = .authorization_pending, .interval_s = 5 }) == .pending);
    try testing.expect(classify(429, .{ .code = .slow_down }) == .slow_down);
    try testing.expect(classify(429, .{ .code = .rate_limited }) == .retryable);
    try testing.expect(classify(409, .{ .code = .conflict }) == .retryable);
    try testing.expect(classify(503, .{}) == .unavailable);
    try testing.expect(classify(403, .{ .code = .plan_limit }) == .terminal);
    try testing.expect(classify(403, .{ .code = .access_denied }) == .terminal);
    try testing.expect(classify(400, .{ .code = .expired_token }) == .terminal);
}

test "classify keeps an unknown code off a known path" {
    // An unknown 403 must never read as a human denial.
    try testing.expect(classify(403, .{}) == .terminal);
    try testing.expect(classify(451, .{}) == .terminal);
    // An unknown 429 still throttles, because the status alone says to slow down.
    try testing.expect(classify(429, .{}) == .retryable);
}
