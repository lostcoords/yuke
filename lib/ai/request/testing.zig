const std = @import("std");
const ir = @import("ir.zig");

pub fn forSerializer(comptime serialize: anytype) type {
    return struct {
        pub fn expectJson(expected: []const u8, request: ir.Request, blocks: []const ir.Block) !void {
            var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer buf.deinit();
            try serialize(&buf.writer, request, blocks);
            try std.testing.expectEqualStrings(expected, buf.written());
        }

        pub fn expectError(expected: anyerror, request: ir.Request, blocks: []const ir.Block) !void {
            var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer buf.deinit();
            try std.testing.expectError(expected, serialize(&buf.writer, request, blocks));
        }
    };
}
