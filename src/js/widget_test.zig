const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;
const Paint = @import("test_paint.zig").Paint;

test "text retains independent measurement and clipped visible rows" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 4, 12);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);
    try support.eval(host, "tests/widget/text-widget.test.js");
    const before = host.paint.counters;
    const repeated = try host.ctx.eval("globalThis.repeat()", "text-repeat.js", .{});
    host.ctx.freeValue(repeated);
    try std.testing.expectEqual(before.wrap_calls, host.paint.counters.wrap_calls);
    try std.testing.expectEqual(before.measure_calls, host.paint.counters.measure_calls);
    try std.testing.expect(host.paint.counters.text_calls > before.text_calls);
}

test "text updates invalidate once and clip an overwide grapheme to its bounds" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/widget/text-invalidate.test.js");
}
