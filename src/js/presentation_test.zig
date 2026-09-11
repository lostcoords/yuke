const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;
const Paint = @import("test_paint.zig").Paint;

test "presentation moves the same composer between welcome and sidebar layouts" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 20, 60);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);
    try support.eval(host, "tests/presentation/presentation-layout.test.js");
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "welcome") != null);
    for ("session details", 0..) |byte, i| {
        const cell = paint.render.vx.screen.readCell(@intCast(42 + i), 0).?;
        try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
    }
    try host.eval("globalThis.finish();", "presentation-finish.js");
}

test "presentation replacement and pane removal release resources and pointer capture" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/presentation/presentation-owner.test.js");
}

test "presentation rejects duplicate mounts and contains factory failures" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/presentation/presentation-failure.test.js");
}

test "presentation cannot retain a view after its scope closes inside a hook" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/presentation/presentation-reentrant.test.js");
}

test "presentation shares view ownership with panes and windows" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/presentation/presentation-shared-owner.test.js");
}

test "default presentation shows welcome text only for an empty chat" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 12, 40);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);
    try support.eval(host, "tests/presentation/presentation-default.test.js");
}
