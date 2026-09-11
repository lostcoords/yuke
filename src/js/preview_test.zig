//! The preview workload pins visible content and source spans before a renderer change.

const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;
const Paint = @import("test_paint.zig").Paint;

test "preview workload keeps bounded rows, full details, and source spans" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 40, 100);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);
    try support.eval(host, "tests/preview/preview.test.js");

    host.paint.counters = .{};
    try support.eval(host, "tests/preview/preview-budget.test.js");
    try std.testing.expect(host.paint.counters.wrap_rows <= 32);
    try std.testing.expect(host.paint.counters.wrap_bytes >= 200_000);
}
