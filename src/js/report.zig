//! Paint a script fault on the bottom row. This path runs no JavaScript.

const std = @import("std");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;

/// The fault row uses white text on a red background and no other color.
const fault_style: term_pkg.Style = .{
    .fg = .{ .index = 15 },
    .bg = .{ .index = 1 },
    .bold = true,
};

/// Paint the fault on the bottom row and flush; the rows above keep the failed script's partial frame.
pub fn paintFault(host: *Host) void {
    std.debug.assert(host.phase == .open);
    const output = host.paint.output orelse return;
    const render = output.render;
    const writer = output.writer;
    const text = host.faultText();
    if (text.len == 0) return;

    const win = render.window();
    if (win.width == 0 or win.height == 0) return;
    const row = win.child(.{
        .x_off = 0,
        .y_off = @intCast(win.height - 1),
        .width = win.width,
        .height = 1,
    });
    std.debug.assert(row.height == 1);
    row.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = fault_style });
    render.writeText(row, text, fault_style) catch return;

    render.render(writer) catch return;
}

const testing = std.testing;

test "a throwing onEvent paints the message on the bottom row" {
    var paint: TestPaint = undefined;
    try paint.setup(testing.allocator, 2, 16);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);

    try host.eval("globalThis.onEvent = function() { throw new Error('boom'); };", "onEvent.js");
    try testing.expectError(error.JavaScriptFault, loop.start(host));
    try testing.expect(std.mem.indexOf(u8, host.faultText(), "boom") != null);

    paint.out.clearRetainingCapacity();
    paintFault(host);
    try testing.expect(std.mem.indexOf(u8, paint.out.written(), "boom") != null);
    @memset(host.fault_text[0..host.fault_text_len], 'X');
    paint.out.clearRetainingCapacity();
    paint.render.queueRefresh();
    try paint.render.render(&paint.out.writer);
    try testing.expect(std.mem.indexOf(u8, paint.out.written(), "boom") != null);
}

test "paintFault does nothing without a recorded fault" {
    var paint: TestPaint = undefined;
    try paint.setup(testing.allocator, 2, 16);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);

    paintFault(host);
    try testing.expectEqual(@as(usize, 0), paint.out.written().len);
}

const support = @import("tests/support.zig");
const TestPaint = @import("tests/paint.zig").Paint;
const loop = @import("loop.zig");
