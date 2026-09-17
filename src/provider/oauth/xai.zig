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
    // The body code decides first because RFC 8628 sends `slow_down` with a 429, and status alone would treat it as a plain retry and drop the interval increase the server requested.
    var buf: [64]u8 = undefined;
    const code = oauth.errorCode(response.body, arena, &buf);
    if (code) |name| {
        if (std.mem.eql(u8, name, "authorization_pending")) return .pending;
        if (std.mem.eql(u8, name, "slow_down")) return .slow_down;
    }
    // The server throttled or failed without a documented code; `Transient` backs the poll off, while `pending` would reset the delay and keep one rate through the outage.
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
    return oauth.refreshOutcome(arena, response, &permanent_refresh, now_ms, tokensFrom);
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

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    body: [512]u8 = undefined,
    canned: oauth.CannedHttp,

    fn init(replies: []const oauth.CannedHttp.Reply) Fixture {
        return .{ .arena = .init(testing.allocator), .canned = .{ .replies = replies } };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
};

test "a start reads the code, prefers the complete url, and defaults the interval" {
    var f = Fixture.init(&.{.{ .answer = .{ .status = 200, .body =
        \\{"device_code":"dc","user_code":"UC","verification_uri":"https://x.ai/d",
        \\ "verification_uri_complete":"https://x.ai/d?code=UC"}
    } }});
    defer f.deinit();

    const s = try start(f.arena.allocator(), f.canned.seam(), &f.body);
    try testing.expectEqualStrings("UC", s.user_code);
    try testing.expectEqualStrings("dc", s.device_auth_id);
    try testing.expectEqualStrings("https://x.ai/d?code=UC", s.verification_url);
    try testing.expectEqual(oauth.default_interval_ms, s.interval_ms);
}

test "a start accepts the usercode spelling" {
    var f = Fixture.init(&.{.{ .answer = .{ .status = 200, .body =
        \\{"device_code":"dc","usercode":"UC","verification_uri":"https://x.ai/d"}
    } }});
    defer f.deinit();

    const s = try start(f.arena.allocator(), f.canned.seam(), &f.body);
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
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = case.status, .body = case.body } }};
        var f = Fixture.init(&replies);
        defer f.deinit();

        const got = try poll(f.arena.allocator(), f.canned.seam(), "dc", 0, &f.body);
        try testing.expectEqual(case.want, std.meta.activeTag(got));
    }
}

test "a throttled or failed poll backs off instead of holding one poll rate" {
    // `pending` adopts the interval and clears the delay, so a status with no code must not use it.
    for ([_]u16{ 408, 429, 503 }) |status| {
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = status, .body = "{}" } }};
        var f = Fixture.init(&replies);
        defer f.deinit();

        try testing.expectError(oauth.Error.Transient, poll(f.arena.allocator(), f.canned.seam(), "dc", 0, &f.body));
    }
}

test "a denied, expired, or unknown poll code ends the login" {
    for ([_][]const u8{
        "{\"error\":\"access_denied\"}",
        "{\"error\":\"something_new\"}",
        "{}",
    }) |body| {
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 400, .body = body } }};
        var f = Fixture.init(&replies);
        defer f.deinit();

        try testing.expectError(oauth.Error.Permanent, poll(f.arena.allocator(), f.canned.seam(), "dc", 0, &f.body));
    }
}

test "a poll that succeeds carries the tokens with no exchange step" {
    var f = Fixture.init(&.{.{ .answer = .{ .status = 200, .body =
        \\{"access_token":"at","refresh_token":"rt","expires_in":60}
    } }});
    defer f.deinit();

    const got = try poll(f.arena.allocator(), f.canned.seam(), "dc", 1000, &f.body);
    try testing.expectEqualStrings("at", got.tokens.access_token);
    try testing.expectEqualStrings("rt", got.tokens.refresh_token.?);
    try testing.expectEqual(@as(u64, 61_000), got.tokens.expires_at_ms);
    try testing.expect(got.tokens.account_id == null);
}

test "a token response with no readable lifetime uses the shared fallback" {
    var f = Fixture.init(&.{.{ .answer = .{ .status = 200, .body = "{\"access_token\":\"at\"}" } }});
    defer f.deinit();

    const got = try poll(f.arena.allocator(), f.canned.seam(), "dc", 1000, &f.body);
    try testing.expectEqual(@as(u64, 1000 + oauth.default_lifetime_ms), got.tokens.expires_at_ms);
    // The caller keeps its old refresh token when the response omits one.
    try testing.expect(got.tokens.refresh_token == null);
}

test "the standard OAuth refresh codes end the grant" {
    for (permanent_refresh) |code| {
        var f = Fixture.init(&.{});
        defer f.deinit();
        const body = try std.fmt.allocPrint(f.arena.allocator(), "{{\"error\":\"{s}\"}}", .{code});
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 400, .body = body } }};
        f.canned.replies = &replies;

        try testing.expectError(oauth.Error.Permanent, refresh(f.arena.allocator(), f.canned.seam(), "rt", 0, &f.body));
    }
}

test "a transport failure keeps a poll alive but ends a refresh" {
    var f = Fixture.init(&.{.{ .fail = error.ConnectionResetByPeer }});
    defer f.deinit();
    try testing.expectError(oauth.Error.Transient, poll(f.arena.allocator(), f.canned.seam(), "dc", 0, &f.body));
    f.canned.index = 0;
    try testing.expectError(oauth.Error.Ambiguous, refresh(f.arena.allocator(), f.canned.seam(), "rt", 0, &f.body));

    // A request that never left is safe to repeat on either call.
    f.canned.replies = &.{.{ .fail = error.PreFlight }};
    f.canned.index = 0;
    try testing.expectError(oauth.Error.PreFlight, refresh(f.arena.allocator(), f.canned.seam(), "rt", 0, &f.body));
}
