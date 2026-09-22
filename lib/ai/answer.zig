//! Read one provider error answer, from a non-200 body or from an error event inside a 200 stream.

const std = @import("std");
const json = @import("stream/json.zig");

/// The provider answered with an error; a status and a stream event map into this one set.
pub const Error = error{
    AuthFailed, // 401
    PermissionDenied, // 403
    RateLimited, // A 429 or an error code that proves a temporary rate limit.
    QuotaExhausted, // A quota, credit, or spend code, or 402.
    RateLimitUnknown, // A 429 the client could not read or decode.
    ServerError, // 5xx, or an overload or server error code.
    BadStatus, // Any other non-200 status.
    StatusTimeout, // 408 or 504. The provider answered.
    ContextOverflow, // The provider reports that the input exceeds the model context window.
    ProviderFailed, // The provider reported an error that no row above names.
};

/// The bound of one detail line.
const max_detail_bytes: usize = 512;

/// Report whether `err` is a provider answer, so a caller keeps the answer bytes.
pub fn isAnswer(err: anyerror) bool {
    inline for (@typeInfo(Error).error_set.?) |member| {
        if (err == @field(Error, member.name)) return true;
    }
    return false;
}

/// Classify a non-200 status. The body refines a 429 and names a context overflow.
pub fn fromStatus(arena: std.mem.Allocator, status: u16, body: ?[]const u8) Error {
    std.debug.assert(status != 200);
    const named = namedIn(arena, body orelse "");
    if (status == 429) {
        // A rate limit must prove itself, and a spend cap shares the status.
        const proven = named orelse return Error.RateLimitUnknown;
        return if (proven == Error.QuotaExhausted or proven == Error.RateLimited) proven else Error.RateLimitUnknown;
    }
    const by_status = byStatus(status);
    if (by_status == Error.BadStatus) if (named) |got| if (got == Error.ContextOverflow) return got;
    return by_status;
}

/// Classify the error fields of a body, or null when the body names no known code.
fn namedIn(arena: std.mem.Allocator, body: []const u8) ?Error {
    const fields = read(parse(arena, body) orelse return null) orelse return null;
    return fields.classify();
}

/// Classify one parsed stream error event. An event that names no known code is a generic provider failure.
pub fn fromEvent(root: std.json.Value) Error {
    const fields = read(root) orelse return Error.ProviderFailed;
    return fields.classify() orelse Error.ProviderFailed;
}

/// Build the bounded detail line from answer bytes: `type: message (code)` when the JSON names them, else the raw text.
pub fn detailText(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?[]const u8 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    const line = if (parse(arena, trimmed)) |root| (try describe(arena, root)) orelse trimmed else trimmed;
    const clean = std.mem.trim(u8, try sanitize(arena, line), " ");
    return if (clean.len == 0) null else clean;
}

/// Hold the error fields of one answer, because each dialect puts them in another place.
const Fields = struct {
    type: ?[]const u8 = null,
    code: ?[]const u8 = null,
    /// OpenRouter puts its stable error class here, whatever API format it serves.
    error_type: ?[]const u8 = null,
    /// A gateway uses a numeric code to repeat the upstream status.
    status: ?i64 = null,
    message: ?[]const u8 = null,
    /// Anthropic names a spend limit here under a rate-limit type.
    detail_code: ?[]const u8 = null,

    fn classify(self: Fields) ?Error {
        const names = [_]?[]const u8{ self.code, self.error_type, self.type, self.detail_code };
        // A spend cap can share a rate-limit type, so a quota name wins over every other name.
        for (names) |name| if (isQuotaCode(name orelse continue)) return Error.QuotaExhausted;
        for (names) |name| if (by_name.get(name orelse continue)) |got| return got;
        const status = std.math.cast(u16, self.status orelse return null) orelse return null;
        if (status < 400) return null;
        const got = byStatus(status);
        return if (got == Error.BadStatus) null else got;
    }
};

/// Map an OpenAI `code`, an OpenRouter `error_type`, or an Anthropic `type` onto the answer set.
const by_name: std.StaticStringMap(Error) = .initComptime(.{
    .{ "context_length_exceeded", Error.ContextOverflow },
    .{ "rate_limit_exceeded", Error.RateLimited },
    .{ "slow_down", Error.RateLimited },
    .{ "rate_limit_error", Error.RateLimited },
    .{ "server_error", Error.ServerError },
    .{ "server_is_overloaded", Error.ServerError },
    .{ "api_error", Error.ServerError },
    .{ "overloaded_error", Error.ServerError },
    .{ "provider_overloaded", Error.ServerError },
    .{ "provider_unavailable", Error.ServerError },
    .{ "server", Error.ServerError },
    .{ "timeout", Error.StatusTimeout },
    .{ "timeout_error", Error.StatusTimeout },
    .{ "authentication", Error.AuthFailed },
    .{ "authentication_error", Error.AuthFailed },
    .{ "permission_denied", Error.PermissionDenied },
    .{ "permission_error", Error.PermissionDenied },
});

/// Find the error fields: `error` (a body or a chunk), `response.error` (`response.failed`), or the root of a flat `error` event.
fn read(root: std.json.Value) ?Fields {
    if (json.fieldGet(root, "error")) |value| switch (value) {
        .string => |text| return .{ .message = text },
        .object => return fieldsOf(value),
        else => {},
    };
    if (json.fieldGet(root, "response")) |response| {
        var fields = fieldsOf(json.fieldGet(response, "error") orelse .null);
        // OpenRouter puts the class of a failed response beside the error object.
        fields.error_type = json.fieldStr(response, "error_type") orelse fields.error_type;
        return fields;
    }
    if (json.fieldStr(root, "type")) |kind| if (std.mem.eql(u8, kind, "error")) return fieldsOf(root);
    return null;
}

/// Read the fields of one error object; any other value names no field.
fn fieldsOf(value: std.json.Value) Fields {
    const details = json.fieldGet(value, "details");
    const metadata = json.fieldGet(value, "metadata");
    return .{
        .type = json.fieldStr(value, "type"),
        .code = json.fieldStr(value, "code"),
        .error_type = json.fieldStr(value, "error_type") orelse if (metadata) |m| json.fieldStr(m, "error_type") else null,
        .status = json.fieldInt(value, "code"),
        .message = json.fieldStr(value, "message"),
        .detail_code = if (details) |d| json.fieldStr(d, "error_code") else null,
    };
}

/// Map a status, and require proof before a 429 can repeat.
fn byStatus(status: u16) Error {
    return switch (status) {
        401 => Error.AuthFailed,
        402 => Error.QuotaExhausted,
        403 => Error.PermissionDenied,
        408, 504 => Error.StatusTimeout,
        429 => Error.RateLimitUnknown,
        500...503, 505...599 => Error.ServerError,
        else => Error.BadStatus,
    };
}

/// Report whether a provider error name names an exhausted quota, credit, or spend limit.
fn isQuotaCode(code: []const u8) bool {
    if (std.mem.eql(u8, code, "insufficient_quota")) return true;
    if (std.mem.eql(u8, code, "payment_required")) return true;
    if (std.mem.eql(u8, code, "billing_error")) return true;
    if (std.mem.eql(u8, code, "enforced_spend_limit_reached")) return true;
    if (std.mem.eql(u8, code, "credit_balance_exhausted")) return true;
    if (std.mem.eql(u8, code, "organization_usage_limit_exceeded")) return true;
    return std.mem.endsWith(u8, code, "_spend_limit_exceeded");
}

fn parse(arena: std.mem.Allocator, bytes: []const u8) ?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch null;
}

/// Write `type: message (code)`, or null when the answer names no message.
fn describe(arena: std.mem.Allocator, root: std.json.Value) error{OutOfMemory}!?[]const u8 {
    const fields = read(root) orelse return null;
    const message = fields.message orelse return null;
    var out: std.ArrayList(u8) = .empty;
    if (fields.type) |kind| if (!std.mem.eql(u8, kind, "error")) try out.print(arena, "{s}: ", .{kind});
    try out.appendSlice(arena, message);
    if (fields.code) |code| try out.print(arena, " ({s})", .{code}) else if (fields.status) |code| try out.print(arena, " ({d})", .{code});
    return try out.toOwnedSlice(arena);
}

/// Copy at most `max_detail_bytes` of valid UTF-8: a C0, DEL, or C1 control becomes a space and an invalid byte becomes `?`.
fn sanitize(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, @min(text.len, max_detail_bytes));
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const valid = i + len <= text.len and std.unicode.utf8ValidateSlice(text[i .. i + len]);
        const control = valid and ((len == 1 and (text[i] < 0x20 or text[i] == 0x7f)) or (len == 2 and text[i] == 0xc2 and text[i + 1] < 0xa0));
        const piece: []const u8 = if (!valid) "?" else if (control) " " else text[i .. i + len];
        if (out.items.len + piece.len > max_detail_bytes) break;
        try out.appendSlice(arena, piece);
        i += if (valid) len else 1;
    }
    return try out.toOwnedSlice(arena);
}

const testing = std.testing;

fn event(arena: std.mem.Allocator, bytes: []const u8) Error {
    return fromEvent(std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch @panic("the fixture is valid JSON"));
}

test "each stream dialect names its error in its own place, and one table classifies them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Responses `response.failed`: the error sits under `response`.
    try testing.expectEqual(Error.RateLimited, event(a, "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"try again\"}}}"));
    try testing.expectEqual(Error.ContextOverflow, event(a, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"}}}"));
    try testing.expectEqual(Error.ServerError, event(a, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_is_overloaded\",\"message\":\"busy\"}}}"));
    // Responses `error`: the fields sit at the root.
    try testing.expectEqual(Error.QuotaExhausted, event(a, "{\"type\":\"error\",\"code\":\"insufficient_quota\",\"message\":\"no credit\",\"param\":null,\"sequence_number\":2}"));
    // Anthropic `error`: an overload in the stream is the 529 of a plain answer.
    try testing.expectEqual(Error.ServerError, event(a, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"));
    // An OpenRouter chunk repeats the upstream status as a number, and a 429 without proof never repeats.
    try testing.expectEqual(Error.RateLimitUnknown, event(a, "{\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\"},\"choices\":[]}"));
    try testing.expectEqual(Error.ServerError, event(a, "{\"error\":{\"code\":502,\"message\":\"upstream\"}}"));
    // OpenRouter names a stable class in each API format, and the class proves what the number cannot.
    try testing.expectEqual(Error.RateLimited, event(a, "{\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\",\"metadata\":{\"error_type\":\"rate_limit_exceeded\"}},\"choices\":[]}"));
    try testing.expectEqual(Error.ContextOverflow, event(a, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"error_type\":\"context_length_exceeded\",\"message\":\"too long\"}}"));
    try testing.expectEqual(Error.ServerError, event(a, "{\"type\":\"response.failed\",\"response\":{\"error_type\":\"provider_overloaded\",\"error\":{\"code\":\"server_error\",\"message\":\"busy\"}}}"));
    try testing.expectEqual(Error.QuotaExhausted, event(a, "{\"type\":\"response.failed\",\"response\":{\"error_type\":\"payment_required\"}}"));
    // Anthropic names a billing failure and a timeout by type.
    try testing.expectEqual(Error.QuotaExhausted, event(a, "{\"type\":\"error\",\"error\":{\"type\":\"billing_error\",\"message\":\"billing\"}}"));
    try testing.expectEqual(Error.StatusTimeout, event(a, "{\"type\":\"error\",\"error\":{\"type\":\"timeout_error\",\"message\":\"slow\"}}"));
    // A code the table does not name, and an event with no fields, stay a generic failure.
    try testing.expectEqual(Error.ProviderFailed, event(a, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"bio_policy\",\"message\":\"refused\"}}}"));
    try testing.expectEqual(Error.ProviderFailed, event(a, "{\"type\":\"response.failed\"}"));
}

test "a status maps alone, and the body only proves a 429 or names a context overflow" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Error.AuthFailed, fromStatus(a, 401, null));
    try testing.expectEqual(Error.ServerError, fromStatus(a, 529, "not json"));
    try testing.expectEqual(Error.StatusTimeout, fromStatus(a, 504, null));
    try testing.expectEqual(Error.RateLimitUnknown, fromStatus(a, 429, ""));
    try testing.expectEqual(Error.RateLimited, fromStatus(a, 429, "{\"error\":{\"code\":\"rate_limit_exceeded\"}}"));
    try testing.expectEqual(Error.QuotaExhausted, fromStatus(a, 429, "{\"error\":{\"code\":\"insufficient_quota\"}}"));
    try testing.expectEqual(Error.QuotaExhausted, fromStatus(a, 429, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}"));
    // A 429 body that proves a server error is still no rate limit.
    try testing.expectEqual(Error.RateLimitUnknown, fromStatus(a, 429, "{\"error\":{\"type\":\"overloaded_error\"}}"));
    try testing.expectEqual(Error.ContextOverflow, fromStatus(a, 400, "{\"error\":{\"message\":\"too long\",\"type\":\"invalid_request_error\",\"code\":\"context_length_exceeded\"}}"));
    try testing.expectEqual(Error.BadStatus, fromStatus(a, 400, "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad\"}}"));
    // A body never overrides a status class other than a plain 4xx.
    try testing.expectEqual(Error.ServerError, fromStatus(a, 500, "{\"error\":{\"code\":\"context_length_exceeded\"}}"));
}

test "the detail line reads the error fields of every dialect and falls back to the raw text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("invalid_request_error: max_tokens is too large", (try detailText(a, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens is too large\"},\"request_id\":\"req_1\"}")).?);
    try testing.expectEqualStrings("invalid_request_error: too long (context_length_exceeded)", (try detailText(a, "{\"error\":{\"message\":\"too long\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"context_length_exceeded\"}}")).?);
    try testing.expectEqualStrings("boom", (try detailText(a, "{\"error\":\"boom\"}")).?);
    try testing.expectEqualStrings("<html> 502 Bad Gateway </html>", (try detailText(a, "  <html>\n502 Bad\tGateway\n</html>\r\n")).?);
    try testing.expectEqualStrings("{\"error\":{\"code\":42}}", (try detailText(a, "{\"error\":{\"code\":42}}")).?);
    try testing.expectEqual(@as(?[]const u8, null), try detailText(a, " \n "));
    // The stream shapes: `response.failed`, a flat `error` event, and a gateway chunk with a numeric code.
    try testing.expectEqualStrings("try again (rate_limit_exceeded)", (try detailText(a, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"try again\"}}}")).?);
    try testing.expectEqualStrings("no credit (insufficient_quota)", (try detailText(a, "{\"type\":\"error\",\"code\":\"insufficient_quota\",\"message\":\"no credit\"}")).?);
    try testing.expectEqualStrings("Rate limit exceeded (429)", (try detailText(a, "{\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\"}}")).?);
}

test "the detail line is bounded on a UTF-8 boundary and never carries an invalid byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "é" ** 300;
    const cut = (try detailText(a, long)).?;
    try testing.expectEqual(max_detail_bytes, cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqualStrings("a?b", (try detailText(a, "a\xffb")).?);
    try testing.expectEqualStrings("a b", (try detailText(a, "a\x1bb")).?);
    try testing.expectEqualStrings("a b", (try detailText(a, "a\xc2\x85b")).?);
    try testing.expectEqualStrings("aé", (try detailText(a, "a\xc2\xa9"[0..1] ++ "é")).?);
    // A lead byte at the end has no second byte to read.
    try testing.expectEqualStrings("a?", (try detailText(a, "a\xc2")).?);
    try testing.expectEqual(@as(?[]const u8, null), try detailText(a, "\x1b\x00"));
}
