//! Project one provider failure onto the wire. The library owns the error table.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");

pub const Class = ai.failure.Class;

/// One error row. The wire message exposes no internal error name.
pub const Detail = struct {
    class: Class,
    code: proto.enums.RunErrorCode,
    message: []const u8,
};

/// Classify one run failure. The engine's own errors answer here; the rest come from the library.
pub fn classify(err: anyerror) Detail {
    return switch (err) {
        // The library never raises these, because they are decisions the engine makes.
        error.ContextHistoryTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the context exceeds the model budget and has no useful compaction cut" },
        error.CompactionSourceTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the history is too large for one summary request" },
        error.CompactionDidNotFit => .{ .class = .permanent, .code = .context_overflow, .message = "the summary and retained history do not reduce the context to fit the model budget" },
        error.IncompleteSummary => .{ .class = .permanent, .code = .provider, .message = "the model did not complete the summary; the context is unchanged" },
        error.EmptySummary => .{ .class = .permanent, .code = .provider, .message = "the model returned an empty summary; the context is unchanged" },
        error.TurnTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the turn is larger than the model context window" },
        error.ContextTooLarge => .{ .class = .permanent, .code = .context_overflow, .message = "the prompt, tools, and output reserve exceed the model context budget" },
        error.UnsupportedReasoning => .{ .class = .permanent, .code = .unsupported_reasoning, .message = "the model does not support this reasoning level" },
        error.PromptTooLarge => .{ .class = .permanent, .code = .runtime, .message = "the system prompt exceeds the protocol string limit" },
        error.HookBlocked => .{ .class = .permanent, .code = .runtime, .message = "an extension stopped the request" },
        error.UnresolvedBlob => .{ .class = .permanent, .code = .runtime, .message = "an attachment names bytes the blob store does not hold" },
        else => {
            const got = ai.failure.classify(err);
            return .{ .class = got.class, .code = codeOf(got.reason), .message = got.reason.message() };
        },
    };
}

/// Name the wire code for one library reason. A new reason must answer here.
fn codeOf(reason: ai.failure.Reason) proto.enums.RunErrorCode {
    return switch (reason) {
        .rate_limited, .rate_limit_unknown => .rate_limited,
        .stream_timeout => .timeout,
        .connect_failed, .dns_failed, .stream_truncated, .connection_lost, .trust_store_failed => .network,
        .malformed_stream, .redirect_refused, .stream_too_large => .protocol,
        .auth_rejected, .permission_denied => .auth,
        .quota_exhausted => .quota_exhausted,
        .out_of_memory => .internal,
        .request_too_large => .context_overflow,
        .malformed_selector, .unknown_provider, .unknown_model => .unknown_model,
        .server_error, .bad_status, .bad_url, .invalid_headers, .unknown => .provider,
    };
}

/// The bound of one detail line on the wire.
pub const max_detail_bytes: usize = 512;

/// Build the bounded detail from an error body: the JSON `error` fields when present, else the raw text.
pub fn detailText(arena: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?[]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return null;
    const line = (try jsonErrorLine(arena, trimmed)) orelse trimmed;
    const clean = std.mem.trim(u8, try sanitize(arena, line), " ");
    return if (clean.len == 0) null else clean;
}

/// Read `error.type: error.message (error.code)` from a provider JSON body, or `error` when it is a string.
fn jsonErrorLine(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const err = field(value, "error") orelse return null;
    switch (err) {
        .string => |s| return s,
        .object => {},
        else => return null,
    }
    const message = stringField(err, "message") orelse return null;
    const kind = stringField(err, "type");
    const code = stringField(err, "code");
    var out: std.ArrayList(u8) = .empty;
    if (kind) |k| try out.print(arena, "{s}: ", .{k});
    try out.appendSlice(arena, message);
    if (code) |c| try out.print(arena, " ({s})", .{c});
    return try out.toOwnedSlice(arena);
}

fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (field(value, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Copy at most `max_detail_bytes` of valid UTF-8: a C0, DEL, or C1 control becomes a space and an invalid byte becomes `?`.
fn sanitize(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, @min(text.len, max_detail_bytes));
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const valid = i + len <= text.len and std.unicode.utf8ValidateSlice(text[i .. i + len]);
        const control = (len == 1 and (text[i] < 0x20 or text[i] == 0x7f)) or (len == 2 and text[i] == 0xc2 and text[i + 1] < 0xa0);
        const piece: []const u8 = if (!valid) "?" else if (control) " " else text[i .. i + len];
        if (out.items.len + piece.len > max_detail_bytes) break;
        try out.appendSlice(arena, piece);
        i += if (valid) len else 1;
    }
    return try out.toOwnedSlice(arena);
}

const testing = std.testing;

test "every transport class reports a network or timeout code" {
    // A retryable connection fault must never reach the client as a generic provider failure.
    for ([_]anyerror{
        ai.transport.HttpError.ConnectFailed,
        ai.transport.HttpError.ConnectionLost,
        ai.transport.HttpError.DnsFailed,
        error.IncompleteStream,
        ai.transport.HttpError.IdleTimeout,
    }) |err| {
        const detail = classify(err);
        try testing.expectEqual(Class.transport, detail.class);
        try testing.expect(detail.code == .network or detail.code == .timeout);
    }
}

test "an unlisted error reports a generic provider failure" {
    const detail = classify(error.SomethingElse);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.provider, detail.code);
}

test "an engine error keeps its own code, which the library cannot name" {
    try testing.expectEqual(proto.enums.RunErrorCode.unsupported_reasoning, classify(error.UnsupportedReasoning).code);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, classify(error.TurnTooLarge).code);
    try testing.expectEqual(proto.enums.RunErrorCode.unknown_model, classify(error.UnknownModel).code);
}

test "the library request bound reports context overflow" {
    const detail = classify(error.RequestTooLarge);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.context_overflow, detail.code);
    try testing.expectEqualStrings("the request exceeds the library size limit", detail.message);
}

test "an extension that stops a request reports a runtime failure" {
    const detail = classify(error.HookBlocked);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.runtime, detail.code);
}

test "a blob the store cannot resolve after admission reports a runtime failure, not a provider one" {
    const detail = classify(error.UnresolvedBlob);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.runtime, detail.code);
}

test "an oversized prompt reports a permanent runtime failure" {
    const detail = classify(error.PromptTooLarge);
    try testing.expectEqual(Class.permanent, detail.class);
    try testing.expectEqual(proto.enums.RunErrorCode.runtime, detail.code);
    try testing.expectEqualStrings("the system prompt exceeds the protocol string limit", detail.message);
}

test "the detail line reads the provider error fields and falls back to the raw text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("invalid_request_error: max_tokens is too large", (try detailText(a, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens is too large\"},\"request_id\":\"req_1\"}")).?);
    try testing.expectEqualStrings("invalid_request_error: too long (context_length_exceeded)", (try detailText(a, "{\"error\":{\"message\":\"too long\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"context_length_exceeded\"}}")).?);
    try testing.expectEqualStrings("boom", (try detailText(a, "{\"error\":\"boom\"}")).?);
    try testing.expectEqualStrings("<html> 502 Bad Gateway </html>", (try detailText(a, "  <html>\n502 Bad\tGateway\n</html>\r\n")).?);
    try testing.expectEqualStrings("{\"error\":{\"code\":42}}", (try detailText(a, "{\"error\":{\"code\":42}}")).?);
    try testing.expectEqual(@as(?[]const u8, null), try detailText(a, " \n "));
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
    try testing.expectEqual(@as(?[]const u8, null), try detailText(a, "\x1b\x00"));
}
