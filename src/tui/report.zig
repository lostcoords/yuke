//! Paint a script fault on the bottom row. This path runs no JavaScript.

const std = @import("std");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;

/// The fault row uses white text on a red background.
/// The style uses no other color.
const fault_style: term_pkg.Style = .{
    .fg = .{ .index = 15 },
    .bg = .{ .index = 1 },
    .bold = true,
};

/// Paint the fault on the bottom row and flush the render.
/// The rows above keep the partial frame that the failed script left.
pub fn paintFault(host: *Host) void {
    std.debug.assert(host.phase == .open);
    const render = host.paint.render orelse return;
    const writer = host.paint.writer orelse return;
    // The Host owns the fault text. The cells hold slices into it during the render.
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
    _ = row.printSegment(.{ .text = text, .style = fault_style }, .{ .wrap = .none });

    render.render(writer) catch return;
    host.paint.dirty = false;
    host.paint.in_frame = false;
}

const testing = std.testing;

/// Build a Host that is bound to `render`. The caller destroys the Host.
fn bindTestHost(
    gpa: std.mem.Allocator,
    render: *term_pkg.Render,
    out: *std.Io.Writer,
) !*Host {
    const host = try Host.create(gpa);
    errdefer host.destroy();
    host.bindRender(render, out);
    return host;
}

test "a throwing onEvent paints the message on the bottom row" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 2, .cols = 16, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try bindTestHost(gpa.allocator(), &render, &out.writer);
    defer host.destroy();

    try host.eval("globalThis.onEvent = function() { throw new Error('boom'); };", "onEvent.js");
    const loop = @import("loop.zig");
    try testing.expectError(error.JavaScriptFault, loop.start(host));
    try testing.expect(std.mem.indexOf(u8, host.faultText(), "boom") != null);

    out.clearRetainingCapacity();
    paintFault(host);
    try testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
}

test "paintFault does nothing without a recorded fault" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 2, .cols = 16, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try bindTestHost(gpa.allocator(), &render, &out.writer);
    defer host.destroy();

    paintFault(host);
    try testing.expectEqual(@as(usize, 0), out.written().len);
}
