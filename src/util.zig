//! Shared helpers for 16-byte IDs and the wall clock.
//! It holds no engine state, so run.zig does not form an import cycle.

const std = @import("std");

/// Build a UUIDv7 from a millisecond timestamp and 10 random bytes. RFC 9562 defines a 48-bit big-endian timestamp.
/// Write the version and variant fields over the random bits.
pub fn v7(ms: u64, rand: [10]u8) [16]u8 {
    std.debug.assert(ms <= std.math.maxInt(u48)); // A real epoch-ms clock never exceeds 48 bits.
    var out: [16]u8 = undefined;
    std.mem.writeInt(u48, out[0..6], @intCast(ms), .big);
    @memcpy(out[6..16], &rand);
    out[6] = 0x70 | (out[6] & 0x0f); // The high nibble holds version 7.
    out[8] = 0x80 | (out[8] & 0x3f); // The top two bits hold variant 10.
    return out;
}

/// Return wall-clock milliseconds since the Unix epoch. Clamp a time before 1970 to 0.
/// This clock is not monotonic. Do not use it for durations or timeouts.
pub fn nowMillis(io: std.Io) u64 {
    return @intCast(@max(std.Io.Timestamp.now(io, .real).toMilliseconds(), 0));
}

/// Mint a fresh UUIDv7 from the wall clock and random bytes.
pub fn newId(io: std.Io) [16]u8 {
    var rand: [10]u8 = undefined;
    io.random(&rand);
    return v7(nowMillis(io), rand);
}

test "v7 stamps the version, variant, and a sortable timestamp" {
    const a = v7(0x0102030405, [_]u8{0xff} ** 10);
    try std.testing.expectEqual(@as(u48, 0x0102030405), std.mem.readInt(u48, a[0..6], .big));
    try std.testing.expectEqual(@as(u8, 0x70), a[6] & 0xf0); // The high nibble holds version 7.
    try std.testing.expectEqual(@as(u8, 0x80), a[8] & 0xc0); // The top two bits hold variant 10.

    // A later timestamp sorts after an earlier one by raw byte order.
    const b = v7(0x0102030406, [_]u8{0} ** 10);
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);
}

/// Draw a jitter in [0, 1) from the UUIDv7 bytes that stay random.
pub fn jitterFrom(id: [16]u8) f64 {
    // Bytes 9..16 hold 56 random bits. Byte 8 carries the variant, so it must not take part.
    var raw: u64 = 0;
    for (id[9..16]) |b| raw = (raw << 8) | b;
    const bits = raw >> 3; // 53 bits fit an f64 exactly
    return @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}
