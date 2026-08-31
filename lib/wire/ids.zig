//! Wire identifiers and revisions.

const std = @import("std");

/// This ID stores `N` bytes as a stable `2*N`-character lowercase hex value, safe in a key path.
pub fn HexId(comptime N: usize) type {
    return struct {
        raw: [N]u8,

        const Self = @This();
        pub const byte_len = N;

        /// Wrap raw bytes as an ID. Use the value at the wire boundary instead of a struct literal.
        pub fn bytes(raw: [N]u8) Self {
            return .{ .raw = raw };
        }

        /// Report whether `text` is a valid wire encoding of this ID.
        pub fn validText(text: []const u8) bool {
            return text.len == N * 2 and isLowerHex(text);
        }

        pub fn jsonStringify(self: Self, jw: *std.json.Stringify) !void {
            const hex = std.fmt.bytesToHex(self.raw, .lower);
            try jw.write(hex[0..]);
        }

        pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !Self {
            const value = try std.json.Value.jsonParse(a, s, o);
            return jsonParseFromValue(a, value, o);
        }

        pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Self {
            const text = switch (value) {
                .string => |text| text,
                else => return error.UnexpectedToken,
            };
            if (text.len != N * 2) return error.LengthMismatch;
            if (!isLowerHex(text)) return error.InvalidCharacter; // The wire accepts lowercase hexadecimal only.
            var self: Self = undefined;
            _ = std.fmt.hexToBytes(&self.raw, text) catch return error.InvalidCharacter;
            return self;
        }
    };
}

/// This ID uses 16 raw bytes and 32 lowercase hexadecimal characters on the wire.
pub const SessionId = HexId(16);
/// This ID uses 16 raw bytes and 32 lowercase hexadecimal characters on the wire.
pub const WorkspaceId = HexId(16);
/// This ID uses 16 raw bytes and 32 lowercase hexadecimal characters on the wire.
pub const RuleId = HexId(16);
/// This ID uses 32 raw bytes and 64 lowercase hexadecimal characters on the wire.
pub const LoginId = HexId(32);
/// This ID uses 64 raw bytes and 128 lowercase hexadecimal characters on the wire.
pub const CatalogRev = HexId(64);

// These IDs are u64; a producer keeps a wire value at or below 2^53-1 for JavaScript.
/// This numeric ID identifies a message.
pub const MessageId = u64;
/// This numeric ID identifies a run.
pub const RunId = u64;
/// This numeric ID identifies an input.
pub const InputId = u64;
/// This numeric ID identifies a message part.
pub const PartId = u64;
/// This numeric value identifies an event sequence.
pub const Seq = u64;
/// This numeric value identifies a session revision.
pub const SessionRevision = u64;
/// This numeric value identifies a run configuration revision.
pub const ConfigRev = u64;

// String IDs use plain slices.
/// This string identifies a provider.
pub const ProviderId = []const u8;
/// This string identifies a model.
pub const ModelId = []const u8;
/// This string identifies a request.
pub const RequestId = []const u8;

/// Bound one half of a selector. Every source shares this limit, so a selector has a fixed maximum.
pub const max_selector_part_bytes = 128;

/// Bound a whole `origin:provider/model` selector. Every durable column holds this many bytes.
pub const max_selector_bytes = 288;

/// Return true when an ID can be the provider half of a selector. A slash would split the selector.
pub fn isSelectorPart(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > max_selector_part_bytes) return false;
    for (bytes) |c| {
        if (c == '/' or std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    }
    return true;
}

/// Return true when an ID can be the model half of a selector. The last half may hold a slash.
pub fn isSelectorTail(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > max_selector_part_bytes) return false;
    for (bytes) |c| {
        if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    }
    return true;
}

/// Return true when every byte is a lowercase hexadecimal digit. This check keeps `[N]u8` IDs safe in paths.
pub fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test isLowerHex {
    try std.testing.expect(isLowerHex("0123456789abcdef"));
    try std.testing.expect(!isLowerHex("0123456789ABCDEF")); // Reject uppercase hexadecimal.
    try std.testing.expect(!isLowerHex("../etc/passwd_xx")); // Reject path characters.
}

test isSelectorPart {
    try std.testing.expect(isSelectorPart("openai"));
    try std.testing.expect(isSelectorPart("claude-4.1:fast"));
    try std.testing.expect(!isSelectorPart(""));
    try std.testing.expect(!isSelectorPart("open/router"));
    try std.testing.expect(!isSelectorPart(" leading"));
    try std.testing.expect(!isSelectorPart("line\nbreak"));
    try std.testing.expect(isSelectorPart("a" ** max_selector_part_bytes));
    try std.testing.expect(!isSelectorPart("a" ** (max_selector_part_bytes + 1)));
}

test isSelectorTail {
    // The model half ends the selector, so a vendor-qualified id keeps its slash.
    try std.testing.expect(isSelectorTail("meta-llama/llama-3.1-405b"));
    try std.testing.expect(!isSelectorTail(""));
    try std.testing.expect(!isSelectorTail("line\nbreak"));
    try std.testing.expect(!isSelectorTail("a" ** (max_selector_part_bytes + 1)));
}

test "two maximal halves that the validators accept still fit the durable bound" {
    // Build the longest selector the validators admit, so the bound tracks the rules, not a literal.
    const provider_id = "a" ** max_selector_part_bytes;
    const model_id = "b" ** max_selector_part_bytes;
    try std.testing.expect(isSelectorPart(provider_id));
    try std.testing.expect(isSelectorTail(model_id));
    var buf: [max_selector_bytes]u8 = undefined;
    // A `bufPrint` overflow here means the durable bound no longer covers what the validators pass.
    const selector = try std.fmt.bufPrint(&buf, "cloud:{s}/{s}", .{ provider_id, model_id });
    try std.testing.expect(selector.len <= max_selector_bytes);
}

test "HexId encodes lowercase hex and rejects uppercase or a wrong length" {
    const Id = HexId(4);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(Id.bytes(.{ 0xab, 0xcd, 0x01, 0x23 }), .{}, &buf.writer);
    try std.testing.expectEqualStrings("\"abcd0123\"", buf.written());

    const decoded = try std.json.parseFromSlice(Id, std.testing.allocator, "\"abcd0123\"", .{});
    defer decoded.deinit();
    try std.testing.expectEqual([_]u8{ 0xab, 0xcd, 0x01, 0x23 }, decoded.value.raw);

    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Id, std.testing.allocator, "\"ABCD0123\"", .{}));
    try std.testing.expectError(error.LengthMismatch, std.json.parseFromSlice(Id, std.testing.allocator, "\"abcd\"", .{}));
}
