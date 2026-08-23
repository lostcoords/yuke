//! Mint 16-byte ids. UUIDv7 stores the time first, which improves locality in the id indexes.

const std = @import("std");

/// Build a UUIDv7 from a millisecond timestamp and 10 random bytes. Per RFC 9562: a 48-bit big-endian
/// timestamp, then random bits with the version and variant fields overwritten.
pub fn v7(ms: u64, rand: [10]u8) [16]u8 {
    std.debug.assert(ms <= std.math.maxInt(u48)); // a real epoch-ms clock never exceeds 48 bits
    var out: [16]u8 = undefined;
    std.mem.writeInt(u48, out[0..6], @intCast(ms), .big);
    @memcpy(out[6..16], &rand);
    out[6] = 0x70 | (out[6] & 0x0f); // version 7 in the high nibble
    out[8] = 0x80 | (out[8] & 0x3f); // variant 10 in the top two bits
    return out;
}

test "v7 stamps the version, variant, and a sortable timestamp" {
    const a = v7(0x0102030405, [_]u8{0xff} ** 10);
    try std.testing.expectEqual(@as(u48, 0x0102030405), std.mem.readInt(u48, a[0..6], .big));
    try std.testing.expectEqual(@as(u8, 0x70), a[6] & 0xf0); // version 7
    try std.testing.expectEqual(@as(u8, 0x80), a[8] & 0xc0); // variant 10

    // A later timestamp sorts after an earlier one by raw byte order.
    const b = v7(0x0102030406, [_]u8{0} ** 10);
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);
}
