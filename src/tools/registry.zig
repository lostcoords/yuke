//! The built-in tool registry. It lists the daemon's native tools and their provider declarations.

const std = @import("std");
const t = @import("tool.zig");
const ir = @import("../provider/request/ir.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");

/// The built-in tools appear in advertisement order.
const builtins = [_]t.Tool{ read.tool, write.tool, edit.tool };

/// Return the built-in with `name`, or null.
pub fn find(name: []const u8) ?t.Tool {
    for (builtins) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// The provider declarations. The compiler builds this static table once.
pub const declarations: []const ir.Tool = &decl_table;

const decl_table = blk: {
    var out: [builtins.len]ir.Tool = undefined;
    for (&out, builtins) |*decl, tool| {
        decl.* = .{ .name = tool.name, .description = tool.description, .input_schema = tool.input_schema };
    }
    const frozen = out;
    break :blk frozen;
};

const testing = std.testing;

test "find returns a built-in by name" {
    try testing.expect(find("read") != null);
    try testing.expect(find("write") != null);
    try testing.expect(find("edit") != null);
    try testing.expect(find("nope") == null);
}

test "declarations carry each built-in schema" {
    try testing.expectEqual(builtins.len, declarations.len);
    try testing.expectEqualStrings(read.tool.input_schema, declarations[0].input_schema);
}
