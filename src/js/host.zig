const std = @import("std");
const quickjs = @import("quickjs");

test "quickjs evaluates on the yuke build" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const r = try quickjs.Runtime.init(gpa.allocator());
    defer r.deinit();

    const ctx = quickjs.Context.init(r);
    defer ctx.deinit();

    const v = try ctx.eval("40 + 2", "smoke.js", .{});
    defer ctx.freeValue(v);
    try std.testing.expectEqual(@as(i32, 42), try ctx.toInt32(v));
}
