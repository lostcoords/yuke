const std = @import("std");
const ir = @import("ir.zig");

pub fn forSerializer(comptime serialize: anytype) type {
    return struct {
        pub fn expectJson(expected: []const u8, request: ir.Request, request_ir: ir.RequestIr) !void {
            var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer buf.deinit();
            try serialize(&buf.writer, request, request_ir);
            try std.testing.expectEqualStrings(expected, buf.written());
        }
    };
}
