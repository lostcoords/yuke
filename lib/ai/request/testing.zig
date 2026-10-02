const std = @import("std");
const ir = @import("ir.zig");
const types = @import("../types.zig");

/// Serialize with the test blob store when the request names none.
pub fn forSerializer(comptime serialize: anytype) type {
    return struct {
        pub fn expectJson(expected: []const u8, request: ir.Request, blocks: []const ir.Block) !void {
            var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer buf.deinit();
            try serialize(&buf.writer, withBlobs(request), blocks);
            try std.testing.expectEqualStrings(expected, buf.written());
        }

        pub fn expectError(expected: anyerror, request: ir.Request, blocks: []const ir.Block) !void {
            var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer buf.deinit();
            try std.testing.expectError(expected, serialize(&buf.writer, withBlobs(request), blocks));
        }
    };
}

fn withBlobs(request: ir.Request) ir.Request {
    var copy = request;
    if (copy.blobs == null) copy.blobs = blobs;
    return copy;
}

/// The test store holds these contents. A test blob names one by its bytes.
const stored = [_][]const u8{ "ab", "cd", "note" };

/// A blob whose digest holds its content, so the test store answers it with no table of digests.
pub fn blob(comptime data: []const u8) types.Blob {
    return .{ .digest = comptime digestOf(data), .len = data.len };
}

/// The test store. It answers each blob from `stored`.
pub const blobs: types.BlobReader = .{ .ctx = &stored, .readFn = read };

fn read(_: *const anyopaque, digest: [32]u8) types.BlobReader.ReadError![]const u8 {
    for (stored) |data| if (std.mem.eql(u8, &digest, &digestOf(data))) return data;
    return error.UnresolvedBlob;
}

fn digestOf(data: []const u8) [32]u8 {
    std.debug.assert(data.len <= 32);
    var digest: [32]u8 = @splat(0);
    @memcpy(digest[0..data.len], data);
    return digest;
}
