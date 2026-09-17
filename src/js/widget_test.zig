const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "text retains independent measurement and clipped visible rows" {
    var fixture = try support.PaintedHost.init(4, 12);
    defer fixture.deinit();
    const host = fixture.host;
    try support.eval(host, "tests/widget/text-widget.test.js");
    const before = host.paint.counters;
    const repeated = try host.ctx.eval("globalThis.repeat()", "text-repeat.js", .{});
    host.ctx.freeValue(repeated);
    try std.testing.expectEqual(before.wrap_calls, host.paint.counters.wrap_calls);
    try std.testing.expectEqual(before.measure_calls, host.paint.counters.measure_calls);
    try std.testing.expect(host.paint.counters.text_calls > before.text_calls);
}

test "text updates invalidate once and clip an overwide grapheme to its bounds" {
    try support.run("tests/widget/text-invalidate.test.js");
}
