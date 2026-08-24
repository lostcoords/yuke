//! Wire identifiers and revisions.

const std = @import("std");

/// A fixed-width binary id. It holds `N` raw bytes and encodes as `2*N` lowercase hex on the wire.
/// Hex is stable for every byte value and is path-safe for a store key.
pub fn HexId(comptime N: usize) type {
    return struct {
        bytes: [N]u8,

        const Self = @This();
        pub const byte_len = N;

        /// Wrap raw bytes as an id. Callers at the wire boundary use this value in place of a struct literal.
        pub fn from(raw: [N]u8) Self {
            return .{ .bytes = raw };
        }

        pub fn jsonStringify(self: Self, jw: *std.json.Stringify) !void {
            const hex = std.fmt.bytesToHex(self.bytes, .lower);
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
            if (!isLowerHex(text)) return error.InvalidCharacter; // the wire uses lowercase hex only
            var self: Self = undefined;
            _ = std.fmt.hexToBytes(&self.bytes, text) catch return error.InvalidCharacter;
            return self;
        }
    };
}

/// Fixed-width session identifier.
pub const SessionId = HexId(16);
/// Fixed-width workspace identifier.
pub const WorkspaceId = HexId(16);
/// Fixed-width permission rule identifier.
pub const RuleId = HexId(16);
/// Fixed-width login identifier.
pub const LoginId = HexId(32);
/// Fixed-width catalog revision identifier.
pub const CatalogRev = HexId(64);

// Numeric ids remain within the 2^53 limit where they cross to JavaScript.
/// Numeric message identifier.
pub const MessageId = u64;
/// Numeric run identifier.
pub const RunId = u64;
/// Numeric input identifier.
pub const InputId = u64;
/// Numeric message-part identifier.
pub const PartId = u64;
/// Numeric event sequence.
pub const Seq = u64;
/// Numeric session revision.
pub const SessionRevision = u64;
/// Numeric run-configuration revision.
pub const ConfigRev = u64;

// Opaque string identifiers are plain slices.
/// Opaque provider identifier.
pub const ProviderId = []const u8;
/// Opaque model identifier.
pub const ModelId = []const u8;
/// Opaque request identifier.
pub const RequestId = []const u8;

/// True when every byte is a lowercase hex digit. The path-safety check for the `[N]u8` ids.
pub fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test isLowerHex {
    try std.testing.expect(isLowerHex("0123456789abcdef"));
    try std.testing.expect(!isLowerHex("0123456789ABCDEF")); // uppercase rejected
    try std.testing.expect(!isLowerHex("../etc/passwd_xx")); // path chars rejected
}

test "HexId encodes lowercase hex and rejects uppercase or a wrong length" {
    const Id = HexId(4);

    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(Id.from(.{ 0xab, 0xcd, 0x01, 0x23 }), .{}, &buf.writer);
    try std.testing.expectEqualStrings("\"abcd0123\"", buf.written());

    const decoded = try std.json.parseFromSlice(Id, std.testing.allocator, "\"abcd0123\"", .{});
    defer decoded.deinit();
    try std.testing.expectEqual([_]u8{ 0xab, 0xcd, 0x01, 0x23 }, decoded.value.bytes);

    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Id, std.testing.allocator, "\"ABCD0123\"", .{}));
    try std.testing.expectError(error.LengthMismatch, std.json.parseFromSlice(Id, std.testing.allocator, "\"abcd\"", .{}));
}
