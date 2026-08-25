//! Wire identifiers and revisions.

const std = @import("std");

/// This ID stores `N` raw bytes and uses `2*N` lowercase hexadecimal characters on the wire.
/// The encoding stays stable for every byte and remains safe in a store key path.
pub fn HexId(comptime N: usize) type {
    return struct {
        raw: [N]u8,

        const Self = @This();
        pub const byte_len = N;

        /// Wrap raw bytes as an ID. Use the value at the wire boundary instead of a struct literal.
        pub fn bytes(raw: [N]u8) Self {
            return .{ .raw = raw };
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

// Numeric IDs stay within the 2^53 limit when they cross to JavaScript.
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

// Opaque string IDs use plain slices.
/// This opaque string identifies a provider.
pub const ProviderId = []const u8;
/// This opaque string identifies a model.
pub const ModelId = []const u8;
/// This opaque string identifies a request.
pub const RequestId = []const u8;

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
