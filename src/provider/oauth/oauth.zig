//! The vocabulary every OAuth device flow shares. Each flow module adds its own wire details.

const std = @import("std");
const http = @import("../../net/http.zig");

/// An absent or non-positive interval becomes this. RFC 8628 leaves the value to the server.
pub const default_interval_ms: u64 = 5_000;

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

/// The transport one flow uses. The daemon backs it with `net.http.Client`; a test replays bytes.
pub const Http = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        post: *const fn (ctx: *anyopaque, req: http.PostRequest) anyerror!http.Response,
    };

    pub fn post(self: Http, req: http.PostRequest) anyerror!http.Response {
        return self.vtable.post(self.ctx, req);
    }
};

/// Back the seam with the real client. One client serves a whole login, so it pools its connection.
pub const ClientHttp = struct {
    client: *http.Client,

    pub fn seam(self: *ClientHttp) Http {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Http.VTable = .{ .post = post };

    fn post(ctx: *anyopaque, req: http.PostRequest) anyerror!http.Response {
        const self: *ClientHttp = @ptrCast(@alignCast(ctx));
        return self.client.post(req);
    }
};

/// Read the provider error code, because a bare string `error` misses `{"code":"..."}`.
pub fn errorCode(body: []const u8, arena: std.mem.Allocator, out: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (parsed != .object) return null;

    if (parsed.object.get("error")) |value| switch (value) {
        .object => |nested| if (nested.get("code")) |code| return lower(code, out),
        .string => return lower(value, out),
        else => {},
    };
    if (parsed.object.get("code")) |value| return lower(value, out);
    if (parsed.object.get("error_code")) |value| return lower(value, out);
    return null;
}

fn lower(value: std.json.Value, out: []u8) ?[]const u8 {
    if (value != .string or value.string.len > out.len) return null;
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
    if (value != .string or value.string.len == 0) return null;
    return arena.dupe(u8, value.string) catch null;
}

/// Read an integer field. Codex sends `interval` as a string and other flows send a number.
pub fn int(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

/// Return the interval one start response asked for. A non-positive value is no value.
pub fn intervalFrom(obj: std.json.ObjectMap) u64 {
    const seconds = int(obj, "interval") orelse return default_interval_ms;
    if (seconds <= 0) return default_interval_ms;
    return @as(u64, @intCast(seconds)) * 1000;
}

const testing = std.testing;

/// Replay scripted replies with no socket, so a test drives every documented branch.
pub const CannedHttp = struct {
    replies: []const Reply,
    index: usize = 0,
    /// The body of the last request, so a test can assert what went on the wire.
    sent: []const u8 = "",

    pub const Reply = union(enum) {
        fail: anyerror,
        answer: struct { status: u16, body: []const u8 },
    };

    pub fn seam(self: *CannedHttp) Http {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Http.VTable = .{ .post = post };

    fn post(ctx: *anyopaque, req: http.PostRequest) anyerror!http.Response {
        const self: *CannedHttp = @ptrCast(@alignCast(ctx));
        if (self.index == self.replies.len) return error.NoCannedReply;
        const reply = self.replies[self.index];
        self.index += 1;
        self.sent = switch (req.payload) {
            .json => |bytes| bytes,
            .form => "",
        };
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

test "the canned seam replays one scripted reply for each call" {
    var canned: CannedHttp = .{ .replies = &.{
        .{ .answer = .{ .status = 403, .body = "{}" } },
        .{ .fail = error.PreFlight },
    } };
    const seam = canned.seam();
    var out: [64]u8 = undefined;

    const first = try seam.post(.{ .url = "https://x.invalid", .payload = .{ .json = "{}" }, .body_out = &out });
    try testing.expectEqual(@as(u16, 403), first.status);
    try testing.expectError(error.PreFlight, seam.post(.{ .url = "https://x.invalid", .payload = .{ .json = "{}" }, .body_out = &out }));
}
