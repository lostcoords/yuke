//! The Codex device flow. It is proprietary, not RFC 8628, and it takes three calls.

const std = @import("std");
const oauth = @import("oauth.zig");

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const user_code_url = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const device_token_url = "https://auth.openai.com/api/accounts/deviceauth/token";
const token_url = "https://auth.openai.com/oauth/token";
/// OpenAI owns this callback, so the flow needs no loopback listener on this machine.
const device_redirect_uri = "https://auth.openai.com/deviceauth/callback";
/// Codex fixes the page the human visits, unlike an RFC 8628 flow that returns one per attempt.
const verification_url = "https://auth.openai.com/codex/device";
/// The id_token claim carrying the account handle that becomes the `ChatGPT-Account-Id` header.
const auth_claim = "https://api.openai.com/auth";

/// Terminal only when the whole grant is gone. Everything else is worth another try.
const permanent_refresh = [_][]const u8{
    "invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
};

/// Step 1. Return the code the human types and the handle the poll uses.
pub fn start(arena: std.mem.Allocator, seam: oauth.Http, body_out: []u8) oauth.Error!oauth.Start {
    const response = seam.post(.{
        .url = user_code_url,
        .payload = .{ .json = "{\"client_id\":\"" ++ client_id ++ "\"}" },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, false);

    if (response.status < 200 or response.status >= 300) return oauth.Error.Transient;
    const obj = oauth.parseObject(arena, response.body) orelse return oauth.Error.BadResponse;

    return .{
        .user_code = oauth.str(arena, obj, "user_code") orelse return oauth.Error.BadResponse,
        .device_auth_id = oauth.str(arena, obj, "device_auth_id") orelse return oauth.Error.BadResponse,
        .interval_ms = oauth.intervalFrom(obj),
        .verification_url = verification_url,
    };
}

/// Step 2 and step 3. Codex signals "not approved yet" with a status, not an RFC 8628 body.
pub fn poll(arena: std.mem.Allocator, seam: oauth.Http, device_auth_id: []const u8, user_code: []const u8, now_ms: u64, body_out: []u8) oauth.Error!oauth.Poll {
    const body = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .device_auth_id = device_auth_id,
        .user_code = user_code,
    }, .{})}) catch return oauth.Error.PreFlight;

    const response = seam.post(.{
        .url = device_token_url,
        .payload = .{ .json = body },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, false);

    if (response.status == 403 or response.status == 404) return .pending;
    if (response.status < 200 or response.status >= 300) return oauth.Error.Transient;

    const grant = oauth.parseObject(arena, response.body) orelse return oauth.Error.BadResponse;
    // The server hands back the verifier, which inverts RFC 7636 where the client generates it.
    const code = oauth.str(arena, grant, "authorization_code") orelse return oauth.Error.BadResponse;
    const verifier = oauth.str(arena, grant, "code_verifier") orelse return oauth.Error.BadResponse;

    return .{ .tokens = try exchange(arena, seam, code, verifier, now_ms, body_out) };
}

/// Step 3 alone. Trade the server-issued code and verifier for tokens, as a form this time.
pub fn exchange(arena: std.mem.Allocator, seam: oauth.Http, code: []const u8, verifier: []const u8, now_ms: u64, body_out: []u8) oauth.Error!oauth.Tokens {
    const response = seam.post(.{
        .url = token_url,
        .payload = .{ .form = &.{
            .{ .name = "grant_type", .value = "authorization_code" },
            .{ .name = "code", .value = code },
            .{ .name = "redirect_uri", .value = device_redirect_uri },
            .{ .name = "client_id", .value = client_id },
            .{ .name = "code_verifier", .value = verifier },
        } },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, false);

    if (response.status < 200 or response.status >= 300) return oauth.Error.Transient;
    const obj = oauth.parseObject(arena, response.body) orelse return oauth.Error.BadResponse;
    return tokensFrom(arena, obj, now_ms);
}

/// Rotate the grant. The new refresh token replaces the old one, which must never be used again.
pub fn refresh(arena: std.mem.Allocator, seam: oauth.Http, refresh_token: []const u8, now_ms: u64, body_out: []u8) oauth.Error!oauth.Tokens {
    if (refresh_token.len == 0) return oauth.Error.Permanent;

    const body = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .client_id = client_id,
        .grant_type = "refresh_token",
        .refresh_token = refresh_token,
    }, .{})}) catch return oauth.Error.PreFlight;

    const response = seam.post(.{
        .url = token_url,
        .payload = .{ .json = body },
        .body_out = body_out,
    }) catch |err| return oauth.classify(err, true);

    if (response.status >= 200 and response.status < 300) {
        const obj = oauth.parseObject(arena, response.body) orelse return oauth.Error.Ambiguous;
        // A 2xx spent the token we sent. An unreadable replacement means it is lost, not retryable.
        return tokensFrom(arena, obj, now_ms) catch oauth.Error.Ambiguous;
    }
    // A 401 means the grant is gone, whatever the body says.
    if (response.status == 401) return oauth.Error.Permanent;

    var buf: [64]u8 = undefined;
    const code = oauth.errorCode(response.body, arena, &buf) orelse return oauth.Error.Transient;
    for (permanent_refresh) |name| if (std.mem.eql(u8, code, name)) return oauth.Error.Permanent;
    return oauth.Error.Transient;
}

/// Read one token response. The lifetime comes from the token itself, because `expires_in` can lie.
fn tokensFrom(arena: std.mem.Allocator, obj: std.json.ObjectMap, now_ms: u64) oauth.Error!oauth.Tokens {
    const access = oauth.str(arena, obj, "access_token") orelse return oauth.Error.BadResponse;
    return .{
        .access_token = access,
        .refresh_token = oauth.str(arena, obj, "refresh_token"),
        .expires_at_ms = expiryFrom(arena, access, obj, now_ms),
        .account_id = accountIdFrom(arena, obj),
    };
}

/// Prefer the JWT `exp`, then `expires_in`, then the shared fallback.
fn expiryFrom(arena: std.mem.Allocator, access: []const u8, obj: std.json.ObjectMap, now_ms: u64) u64 {
    // The token states its own deadline, so a non-positive claim means it already lapsed.
    if (jwtClaims(arena, access)) |claims| {
        if (oauth.int(claims, "exp")) |exp| return oauth.deadlineMs(0, exp) orelse 0;
    }
    const lifetime = oauth.int(obj, "expires_in") orelse 0;
    return oauth.deadlineMs(now_ms, lifetime) orelse now_ms +| oauth.default_lifetime_ms;
}

/// Read the account handle the request header pins. It is a label, not a secret.
fn accountIdFrom(arena: std.mem.Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    const id_token = oauth.str(arena, obj, "id_token") orelse return null;
    const claims = jwtClaims(arena, id_token) orelse return null;
    const auth = claims.get(auth_claim) orelse return null;
    if (auth != .object) return null;
    return oauth.str(arena, auth.object, "chatgpt_account_id");
}

/// Read a transport-authenticated token without its signature, so this decides no authorization.
fn jwtClaims(arena: std.mem.Allocator, token: []const u8) ?std.json.ObjectMap {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload = parts.next() orelse return null;
    if (payload.len == 0) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return null;
    const raw = arena.alloc(u8, size) catch return null;
    decoder.decode(raw, payload) catch return null;
    return oauth.parseObject(arena, raw);
}

const testing = std.testing;

/// Build one JWT with `payload` as its claims. Only the middle segment is ever read.
fn jwt(arena: std.mem.Allocator, payload: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const body = try arena.alloc(u8, encoder.calcSize(payload.len));
    _ = encoder.encode(body, payload);
    return std.fmt.allocPrint(arena, "header.{s}.signature", .{body});
}

test "a start reads the codex handle and its fixed verification page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body =
        \\{"user_code":"UC","device_auth_id":"dai","interval":"7"}
    } }} };

    const s = try start(arena.allocator(), canned.seam(), &out);
    try testing.expectEqualStrings("UC", s.user_code);
    try testing.expectEqualStrings("dai", s.device_auth_id);
    try testing.expectEqualStrings(verification_url, s.verification_url);
    // Codex sends the interval as a string where other flows send a number.
    try testing.expectEqual(@as(u64, 7000), s.interval_ms);
    // The wire request must name the right endpoint and carry the client id.
    try testing.expectEqualStrings(user_code_url, canned.sent.?.url);
    try testing.expect(std.mem.indexOf(u8, canned.sent.?.payload.json, client_id) != null);
}

test "a 403 and a 404 both mean the human has not approved yet" {
    for ([_]u16{ 403, 404 }) |status| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: [512]u8 = undefined;
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = status, .body = "{}" } }};
        var canned: oauth.CannedHttp = .{ .replies = &replies };

        const got = try poll(arena.allocator(), canned.seam(), "dai", "UC", 0, &out);
        try testing.expectEqual(std.meta.Tag(oauth.Poll).pending, std.meta.activeTag(got));
    }
}

test "an approved poll exchanges the server-issued code and verifier for tokens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [512]u8 = undefined;
    var canned: oauth.CannedHttp = .{ .replies = &.{
        .{ .answer = .{ .status = 200, .body = "{\"authorization_code\":\"ac\",\"code_verifier\":\"cv\"}" } },
        .{ .answer = .{ .status = 200, .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":60}" } },
    } };

    const got = try poll(arena.allocator(), canned.seam(), "dai", "UC", 1000, &out);
    try testing.expectEqualStrings("at", got.tokens.access_token);
    try testing.expectEqualStrings("rt", got.tokens.refresh_token.?);
    try testing.expectEqual(@as(u64, 61_000), got.tokens.expires_at_ms);
    // Both calls ran, so the exchange really followed the poll.
    try testing.expectEqual(@as(usize, 2), canned.index);
}

test "a device grant missing either half is unusable" {
    for ([_][]const u8{
        "{\"authorization_code\":\"ac\"}",
        "{\"code_verifier\":\"cv\"}",
    }) |body| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: [512]u8 = undefined;
        const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 200, .body = body } }};
        var canned: oauth.CannedHttp = .{ .replies = &replies };

        try testing.expectError(oauth.Error.BadResponse, poll(arena.allocator(), canned.seam(), "dai", "UC", 0, &out));
    }
}

test "the expiry prefers the jwt claim over expires_in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [1024]u8 = undefined;

    const access = try jwt(a, "{\"exp\":1700000000}");
    const body = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"expires_in\":60}}", .{access});
    const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 200, .body = body } }};
    var canned: oauth.CannedHttp = .{ .replies = &replies };

    const got = try exchange(a, canned.seam(), "ac", "cv", 1000, &out);
    try testing.expectEqual(@as(u64, 1_700_000_000_000), got.expires_at_ms);
}

test "the account id comes from the id_token claim and is not a secret" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [1024]u8 = undefined;

    const id_token = try jwt(a, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-1\"}}");
    const body = try std.fmt.allocPrint(a, "{{\"access_token\":\"at\",\"id_token\":\"{s}\"}}", .{id_token});
    const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 200, .body = body } }};
    var canned: oauth.CannedHttp = .{ .replies = &replies };

    const got = try exchange(a, canned.seam(), "ac", "cv", 0, &out);
    try testing.expectEqualStrings("acct-1", got.account_id.?);
}

test "an unreadable jwt falls back instead of failing the login" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [512]u8 = undefined;
    // The token is opaque, so neither the expiry nor the account id can be read from it.
    const replies = [_]oauth.CannedHttp.Reply{.{ .answer = .{ .status = 200, .body = "{\"access_token\":\"opaque\",\"id_token\":\"also-opaque\"}" } }};
    var canned: oauth.CannedHttp = .{ .replies = &replies };

    const got = try exchange(a, canned.seam(), "ac", "cv", 1000, &out);
    try testing.expectEqual(@as(u64, 1000 + oauth.default_lifetime_ms), got.expires_at_ms);
    try testing.expect(got.account_id == null);
}

test "each documented refresh failure maps to one class" {
    const Case = struct { status: u16, body: []const u8, want: oauth.Error };
    for ([_]Case{
        .{ .status = 401, .body = "{}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"refresh_token_expired\"}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"refresh_token_reused\"}", .want = oauth.Error.Permanent },
        .{ .status = 400, .body = "{\"error\":\"refresh_token_invalidated\"}", .want = oauth.Error.Permanent },
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
    var canned: oauth.CannedHttp = .{ .replies = &.{.{ .answer = .{ .status = 200, .body = "{\"nonsense\":true}" } }} };

    try testing.expectError(oauth.Error.Ambiguous, refresh(arena.allocator(), canned.seam(), "rt", 0, &out));
}
