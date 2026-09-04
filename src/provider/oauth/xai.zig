//! The xAI device flow. It is RFC 8628, so the poll returns tokens and there is no exchange step.

const std = @import("std");
const oauth = @import("oauth.zig");

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const scope = "openid profile email offline_access grok-cli:access api:access";
/// xAI reads the client identity from `referrer`, not from `originator`.
const referrer = "yuke";
const device_grant_type = "urn:ietf:params:oauth:grant-type:device_code";
const device_code_url = "https://auth.x.ai/oauth2/device/code";
const token_url = "https://auth.x.ai/oauth2/token";

/// The standard OAuth terminal refresh errors. Anything else is worth another try.
const permanent_refresh = [_][]const u8{ "invalid_grant", "invalid_client", "unauthorized_client" };

/// Ask xAI for a code the human types. RFC 8628 returns the page per attempt, so it is not fixed.
pub fn start(arena: std.mem.Allocator, seam: oauth.Http, body_out: []u8) oauth.Error!oauth.Start {
    const response = seam.post(.{
        .url = device_code_url,
        .payload = .{ .form = &.{
            .{ .name = "client_id", .value = client_id },
            .{ .name = "scope", .value = scope },
            .{ .name = "referrer", .value = referrer },
        } },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, false);

    if (response.status < 200 or response.status >= 300) return oauth.Error.Transient;
    const obj = oauth.parseObject(arena, response.body) orelse return oauth.Error.BadResponse;

    const device_code = oauth.str(arena, obj, "device_code") orelse return oauth.Error.BadResponse;
    const user_code = oauth.str(arena, obj, "user_code") orelse
        oauth.str(arena, obj, "usercode") orelse return oauth.Error.BadResponse;
    // The complete form already carries the code, so the human need not retype it.
    const verification = oauth.str(arena, obj, "verification_uri_complete") orelse
        oauth.str(arena, obj, "verification_uri") orelse return oauth.Error.BadResponse;

    return .{
        .user_code = user_code,
        .device_auth_id = device_code,
        .interval_ms = oauth.intervalFrom(obj),
        .verification_url = verification,
    };
}

/// Ask whether the human approved yet. RFC 8628 identifies the attempt by device code alone.
pub fn poll(arena: std.mem.Allocator, seam: oauth.Http, device_auth_id: []const u8, now_ms: u64, body_out: []u8) oauth.Error!oauth.Poll {
    const response = seam.post(.{
        .url = token_url,
        .payload = .{ .form = &.{
            .{ .name = "grant_type", .value = device_grant_type },
            .{ .name = "device_code", .value = device_auth_id },
            .{ .name = "client_id", .value = client_id },
        } },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, false);

    if (response.status >= 200 and response.status < 300) {
        const obj = oauth.parseObject(arena, response.body) orelse return oauth.Error.BadResponse;
        return .{ .tokens = try tokensFrom(arena, obj, now_ms) };
    }
    // The body code decides first. RFC 8628 sends `slow_down` with a 429, and the status alone
    // would read that as a plain retry and drop the interval increase the server asked for.
    var buf: [64]u8 = undefined;
    const code = oauth.errorCode(response.body, arena, &buf);
    if (code) |name| {
        if (std.mem.eql(u8, name, "authorization_pending")) return .pending;
        if (std.mem.eql(u8, name, "slow_down")) return .slow_down;
    }
    // The server throttled or failed without a documented code. `Transient` backs the poll off,
    // where `pending` would reset the delay and keep one rate through the whole outage.
    if (response.status == 408 or response.status == 429 or response.status >= 500) return oauth.Error.Transient;
    // `access_denied` and `expired_token` end the login, and so does a code this flow cannot read.
    return oauth.Error.Permanent;
}

/// Rotate the grant. xAI may omit a new refresh token, and the caller then keeps the old one.
pub fn refresh(arena: std.mem.Allocator, seam: oauth.Http, refresh_token: []const u8, now_ms: u64, body_out: []u8) oauth.Error!oauth.Tokens {
    if (refresh_token.len == 0) return oauth.Error.Permanent;

    const response = seam.post(.{
        .url = token_url,
        .payload = .{ .form = &.{
            .{ .name = "grant_type", .value = "refresh_token" },
            .{ .name = "client_id", .value = client_id },
            .{ .name = "refresh_token", .value = refresh_token },
        } },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, true);

    if (response.status >= 200 and response.status < 300) {
        const obj = oauth.parseObject(arena, response.body) orelse return oauth.Error.Ambiguous;
        // A 2xx spent the token we sent. An unreadable replacement means it is lost, not retryable.
        return tokensFrom(arena, obj, now_ms) catch oauth.Error.Ambiguous;
    }
    if (response.status == 401) return oauth.Error.Permanent;

    var buf: [64]u8 = undefined;
    const code = oauth.errorCode(response.body, arena, &buf) orelse return oauth.Error.Transient;
    for (permanent_refresh) |name| if (std.mem.eql(u8, code, name)) return oauth.Error.Permanent;
    return oauth.Error.Transient;
}

/// Read one token response. xAI pins no per-account header, so the account id stays null.
fn tokensFrom(arena: std.mem.Allocator, obj: std.json.ObjectMap, now_ms: u64) oauth.Error!oauth.Tokens {
    const access = oauth.str(arena, obj, "access_token") orelse return oauth.Error.BadResponse;
    const lifetime = oauth.int(obj, "expires_in") orelse 0;
    return .{
        .access_token = access,
        .refresh_token = oauth.str(arena, obj, "refresh_token"),
        .expires_at_ms = oauth.deadlineMs(now_ms, lifetime) orelse now_ms +| oauth.default_lifetime_ms,
    };
}

const testing = std.testing;

test "a start reads the code, prefers the complete url, and defaults the interval" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body =
        \\{"device_code":"dc","user_code":"UC","verification_uri":"https://x.ai/d",
        \\ "verification_uri_complete":"https://x.ai/d?code=UC"}
    } }} };

    const s = try start(arena.allocator(), canned.seam(), &out);
    try testing.expectEqualStrings("UC", s.user_code);
    try testing.expectEqualStrings("dc", s.device_auth_id);
    try testing.expectEqualStrings("https://x.ai/d?code=UC", s.verification_url);
    try testing.expectEqual(oauth.default_interval_ms, s.interval_ms);
}

test "a start accepts the usercode spelling" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body =
        \\{"device_code":"dc","usercode":"UC","verification_uri":"https://x.ai/d"}
    } }} };

    const s = try start(arena.allocator(), canned.seam(), &out);
    try testing.expectEqualStrings("UC", s.user_code);
}

test "each documented poll status and code maps to one outcome" {
    const Case = struct { status: u16, body: []const u8, want: std.meta.Tag(oauth.Poll) };
    for ([_]Case{
        .{ .status = 400, .body = "{\"error\":\"authorization_pending\"}", .want = .pending },
        .{ .status = 400, .body = "{\"error\":\"slow_down\"}", .want = .slow_down },
        // RFC 8628 section 3.5 pairs `slow_down` with a 429, so the code decides before the status.
        .{ .status = 429, .body = "{\"error\":\"slow_down\"}", .want = .slow_down },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: [512]u8 = undefined;
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = case.status, .body = case.body } }};
        var canned: oauth.CannedHttp = .{ .replies = &replies };

        const got = try poll(arena.allocator(), canned.seam(), "dc", 0, &out);
        try testing.expectEqual(case.want, std.meta.activeTag(got));
    }
}

test "a throttled or failed poll backs off instead of holding one poll rate" {
    // `pending` adopts the interval and clears the delay, so a status with no code must not use it.
    for ([_]u16{ 408, 429, 503 }) |status| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: [512]u8 = undefined;
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = status, .body = "{}" } }};
        var canned: oauth.CannedHttp = .{ .replies = &replies };

        try testing.expectError(oauth.Error.Transient, poll(arena.allocator(), canned.seam(), "dc", 0, &out));
    }
}

test "a denied, expired, or unknown poll code ends the login" {
    for ([_][]const u8{
        "{\"error\":\"access_denied\"}",
        "{\"error\":\"something_new\"}",
        "{}",
    }) |body| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: [512]u8 = undefined;
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 400, .body = body } }};
        var canned: oauth.CannedHttp = .{ .replies = &replies };

        try testing.expectError(oauth.Error.Permanent, poll(arena.allocator(), canned.seam(), "dc", 0, &out));
    }
}

test "a poll that succeeds carries the tokens with no exchange step" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body =
        \\{"access_token":"at","refresh_token":"rt","expires_in":60}
    } }} };

    const got = try poll(arena.allocator(), canned.seam(), "dc", 1000, &out);
    try testing.expectEqualStrings("at", got.tokens.access_token);
    try testing.expectEqualStrings("rt", got.tokens.refresh_token.?);
    try testing.expectEqual(@as(u64, 61_000), got.tokens.expires_at_ms);
    try testing.expect(got.tokens.account_id == null);
}

test "a token response with no readable lifetime uses the shared fallback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body = "{\"access_token\":\"at\"}" } }} };

    const got = try poll(arena.allocator(), canned.seam(), "dc", 1000, &out);
    try testing.expectEqual(@as(u64, 1000 + oauth.default_lifetime_ms), got.tokens.expires_at_ms);
    // The caller keeps its old refresh token when the response omits one.
    try testing.expect(got.tokens.refresh_token == null);
}

test "each documented refresh failure maps to one class" {
    const Case = struct { status: u16, body: []const u8, want: oauth.Error };
    for ([_]Case{
        .{ .status = 401, .body = "{}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"invalid_client\"}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"unauthorized_client\"}", .want = oauth.Error.Permanent },
        // An unrecognized code is worth another try, because giving up costs the whole grant.
        .{ .status = 400, .body = "{\"error\":\"teapot\"}", .want = oauth.Error.Transient },
        .{ .status = 500, .body = "{}", .want = oauth.Error.Transient },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: [512]u8 = undefined;
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = case.status, .body = case.body } }};
        var canned: oauth.CannedHttp = .{ .replies = &replies };

        try testing.expectError(case.want, refresh(arena.allocator(), canned.seam(), "rt", 0, &out));
    }
}

test "a rotated token that cannot be read is ambiguous, never retryable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    // The 2xx spent the token we sent, so a body we cannot read has lost the replacement.
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body = "{\"nonsense\":true}" } }} };

    try testing.expectError(oauth.Error.Ambiguous, refresh(arena.allocator(), canned.seam(), "rt", 0, &out));
}

test "a transport failure keeps a poll alive but ends a refresh" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;

    var timed_out: oauth.CannedHttp = .{ .replies = &.{.{ .fail = error.ConnectionResetByPeer }} };
    try testing.expectError(oauth.Error.Transient, poll(arena.allocator(), timed_out.seam(), "dc", 0, &out));

    var rotating: oauth.CannedHttp = .{ .replies = &.{.{ .fail = error.ConnectionResetByPeer }} };
    try testing.expectError(oauth.Error.Ambiguous, refresh(arena.allocator(), rotating.seam(), "rt", 0, &out));

    // A request that never left is safe to repeat on either call.
    var never_left: oauth.CannedHttp = .{ .replies = &.{.{ .fail = error.PreFlight }} };
    try testing.expectError(oauth.Error.PreFlight, refresh(arena.allocator(), never_left.seam(), "rt", 0, &out));
}
