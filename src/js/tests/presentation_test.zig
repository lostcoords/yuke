const support = @import("support.zig");
const std = @import("std");
const Host = @import("../host.zig").Host;

test "presentation moves the same composer between welcome and sidebar layouts" {
    var fixture = try support.PaintedHost.init(20, 60);
    defer fixture.deinit();
    const host = fixture.host;
    try support.eval(host, "presentation/presentation-layout.test.js");
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "welcome") != null);
    for ("session details", 0..) |byte, i| {
        const cell = fixture.paint.render.vx.screen.readCell(@intCast(42 + i), 0).?;
        try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
    }
    try host.eval("globalThis.finish();", "presentation-finish.js");
}

test "presentation replacement and pane removal release resources and pointer capture" {
    try support.run("presentation/presentation-owner.test.js");
}

test "presentation rejects duplicate mounts and contains factory failures" {
    try support.run("presentation/presentation-failure.test.js");
}

test "presentation cannot retain a view after its scope closes inside a hook" {
    try support.run("presentation/presentation-reentrant.test.js");
}

test "presentation shares view ownership with panes and windows" {
    try support.run("presentation/presentation-shared-owner.test.js");
}

test "default presentation shows welcome text only for an empty chat" {
    try support.runPainted(12, 40, "presentation/presentation-default.test.js");
}
