//! The vocabulary every OAuth device flow shares. Each flow module adds its own wire details.

const std = @import("std");
const http = @import("../../net/http.zig");

/// An absent, non-positive, or absurd interval becomes this. RFC 8628 leaves the value to the server.
pub const default_interval_ms: u64 = 5_000;

/// No device flow polls slower than this, so a larger value is garbage rather than a cadence.
const max_interval_ms: u64 = 60 * 60 * 1000;

/// A lifetime this long stops a short fallback from rotating a ten-day grant for nothing.
pub const default_lifetime_ms: u64 = 5 * 60 * 60 * 1000;

/// What one device login shows the human. The flow reads it from the start response.
pub const Start = struct {
    user_code: []const u8,
    device_auth_id: []const u8,
    interval_ms: u64 = default_interval_ms,
    verification_url: []const u8,
};

/// One grant. The caller keeps its old refresh token when a refresh omits a new one.
pub const Tokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at_ms: u64,
    account_id: ?[]const u8 = null,
};

/// What one poll learned. Only `tokens` ends the login.
pub const Poll = union(enum) {
    /// The human has not approved yet, or the provider asked to wait. Poll again at the interval.
    pending,
    /// RFC 8628 section 3.5 pacing. Widen the interval, then poll again.
    slow_down,
    tokens: Tokens,
};

/// A flow failure. `PreFlight` alone permits a retry with the same token.
pub const Error = error{
    /// The request never left this host, so a repeat cannot look like token reuse.
    PreFlight,
    /// The call carried no rotating token, so the caller may repeat it.
    Transient,
    /// The server may already hold the request, so a refresh must never repeat it.
    Ambiguous,
    /// The grant is gone and only a fresh login recovers it.
    Permanent,
    /// The provider answered with something this flow cannot read.
    BadResponse,
};

/// The transport one flow uses. The engine backs it with `net.http.Client`; a test replays bytes.
/// One call is the whole seam, so the function pointer is the interface.
pub const Http = struct {
    ctx: *anyopaque,
    post_fn: *const fn (ctx: *anyopaque, req: http.PostRequest) anyerror!http.Response,

    /// Back the seam with the real client. One client serves a whole login and pools its connection.
    pub fn fromClient(client: *http.Client) Http {
        return .{ .ctx = client, .post_fn = postClient };
    }

    pub fn post(self: Http, req: http.PostRequest) anyerror!http.Response {
        return self.post_fn(self.ctx, req);
    }

    fn postClient(ctx: *anyopaque, req: http.PostRequest) anyerror!http.Response {
        const client: *http.Client = @ptrCast(@alignCast(ctx));
        return client.post(req);
    }
};

/// Read the provider error code, because a bare string `error` misses `{"code":"..."}`.
pub fn errorCode(body: []const u8, arena: std.mem.Allocator, out: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (parsed != .object) return null;

    const nested: ?std.json.Value = if (parsed.object.get("error")) |value| switch (value) {
        .object => |obj| obj.get("code"),
        else => null,
    } else null;

    // The first name that holds a usable string wins, so an empty one falls through to the next.
    for ([_]?std.json.Value{ nested, parsed.object.get("error"), parsed.object.get("code"), parsed.object.get("error_code") }) |candidate| {
        if (candidate) |value| if (lower(value, out)) |code| return code;
    }
    return null;
}

fn lower(value: std.json.Value, out: []u8) ?[]const u8 {
    if (value != .string or value.string.len == 0 or value.string.len > out.len) return null;
    return std.ascii.lowerString(out[0..value.string.len], value.string);
}

/// Classify one transport failure. A rotating call spends its token, so it cannot repeat one.
pub fn classify(err: anyerror, rotating: bool) Error {
    if (err == error.PreFlight) return Error.PreFlight;
    return if (rotating) Error.Ambiguous else Error.Transient;
}

/// Parse one response body as a JSON object. Any other shape is unreadable.
pub fn parseObject(arena: std.mem.Allocator, body: []const u8) ?std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    return if (parsed == .object) parsed.object else null;
}

/// Read a non-empty string field. The result is a copy, because the body buffer is reused.
pub fn str(arena: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return null;
    if (std.mem.trim(u8, value.string, &std.ascii.whitespace).len == 0) return null;
    return arena.dupe(u8, value.string) catch null;
}

/// Read an integer field. Codex sends `interval` as a string and other flows send a number.
pub fn int(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        // A float outside the integer range would trap, so clamp it instead.
        .float => |f| std.math.lossyCast(i64, f),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

/// Convert peer seconds into a deadline. Saturating math keeps a hostile value from wrapping.
pub fn deadlineMs(now_ms: u64, seconds: i64) ?u64 {
    if (seconds <= 0) return null;
    return now_ms +| (@as(u64, @intCast(seconds)) *| 1000);
}

/// Return the interval one start response asked for. A non-positive value is no value.
pub fn intervalFrom(obj: std.json.ObjectMap) u64 {
    const seconds = int(obj, "interval") orelse return default_interval_ms;
    const ms = deadlineMs(0, seconds) orelse return default_interval_ms;
    return if (ms > max_interval_ms) default_interval_ms else ms;
}

const testing = std.testing;

/// Replay scripted replies with no socket, so a test drives every documented branch.
pub const CannedHttp = struct {
    replies: []const Reply,
    index: usize = 0,
    /// The last request, so a test can assert the url and the fields that went on the wire.
    sent: ?http.PostRequest = null,

    pub const Reply = union(enum) {
        fail: anyerror,
        answer: struct { status: u16, body: []const u8 },
    };

    pub fn seam(self: *CannedHttp) Http {
        return .{ .ctx = self, .post_fn = post };
    }

    fn post(ctx: *anyopaque, req: http.PostRequest) anyerror!http.Response {
        const self: *CannedHttp = @ptrCast(@alignCast(ctx));
        if (self.index == self.replies.len) return error.NoCannedReply;
        const reply = self.replies[self.index];
        self.index += 1;
        self.sent = req;
        return switch (reply) {
            .fail => |err| err,
            .answer => |a| blk: {
                if (a.body.len > req.body_out.len) break :blk error.ResponseTooLarge;
                @memcpy(req.body_out[0..a.body.len], a.body);
                break :blk .{ .status = a.status, .body = req.body_out[0..a.body.len] };
            },
        };
    }
};

test "the error code reads the four documented names in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("invalid_grant", errorCode("{\"error\":{\"code\":\"INVALID_GRANT\"}}", a, &buf).?);
    try testing.expectEqualStrings("slow_down", errorCode("{\"error\":\"slow_down\"}", a, &buf).?);
    try testing.expectEqualStrings("expired_token", errorCode("{\"code\":\"expired_token\"}", a, &buf).?);
    try testing.expectEqualStrings("access_denied", errorCode("{\"error_code\":\"access_denied\"}", a, &buf).?);
    try testing.expect(errorCode("{\"other\":1}", a, &buf) == null);
    try testing.expect(errorCode("not json", a, &buf) == null);
}

test "a rotating call cannot repeat what a poll may repeat" {
    try testing.expectEqual(Error.PreFlight, classify(error.PreFlight, true));
    try testing.expectEqual(Error.PreFlight, classify(error.PreFlight, false));
    // The refresh spent its token, so an unknown outcome is terminal.
    try testing.expectEqual(Error.Ambiguous, classify(error.CloudTimeout, true));
    // The poll holds a reusable device code, so the same failure keeps the login alive.
    try testing.expectEqual(Error.Transient, classify(error.CloudTimeout, false));
}

test "an interval falls back when it is absent, zero, or a string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(default_interval_ms, intervalFrom(parseObject(a, "{}").?));
    try testing.expectEqual(default_interval_ms, intervalFrom(parseObject(a, "{\"interval\":0}").?));
    try testing.expectEqual(@as(u64, 7000), intervalFrom(parseObject(a, "{\"interval\":7}").?));
    // Codex sends this field as a string.
    try testing.expectEqual(@as(u64, 7000), intervalFrom(parseObject(a, "{\"interval\":\"7\"}").?));
}

test "the error code prefers the first name that holds a usable string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [64]u8 = undefined;

    // Every name is present, so the documented order decides.
    try testing.expectEqualStrings("first", errorCode("{\"error\":{\"code\":\"first\"},\"code\":\"third\",\"error_code\":\"fourth\"}", a, &buf).?);
    // An unusable higher name falls through instead of ending the search.
    try testing.expectEqualStrings("third", errorCode("{\"error\":\"\",\"code\":\"third\"}", a, &buf).?);
    try testing.expectEqualStrings("third", errorCode("{\"error\":{\"code\":0},\"code\":\"third\"}", a, &buf).?);
}

test "a hostile number never traps and never wraps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A float beyond i64 clamps, and the seconds then saturate instead of wrapping.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), int(parseObject(a, "{\"n\":1e300}").?, "n").?);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), deadlineMs(0, std.math.maxInt(i64)).?);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), deadlineMs(std.math.maxInt(u64), 1).?);
    try testing.expect(deadlineMs(0, -1) == null);
    try testing.expectEqual(default_interval_ms, intervalFrom(parseObject(a, "{\"interval\":1e300}").?));
}

test "a blank string is no value, so a fallback field still gets its turn" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const obj = parseObject(a, "{\"blank\":\"   \",\"empty\":\"\",\"kept\":\" v \"}").?;

    try testing.expect(str(a, obj, "blank") == null);
    try testing.expect(str(a, obj, "empty") == null);
    // A value with content keeps its own spacing, because only the blank test trims.
    try testing.expectEqualStrings(" v ", str(a, obj, "kept").?);
}
