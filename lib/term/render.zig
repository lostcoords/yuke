const std = @import("std");
const xvaxis = @import("xvaxis/main.zig");

pub const Options = xvaxis.Vaxis.Options;
pub const Window = xvaxis.Window;
pub const Winsize = xvaxis.Winsize;

/// A frame transaction over xvaxis. The caller owns the writer and environment.
pub const Render = struct {
    vx: xvaxis.Vaxis,
    alloc: std.mem.Allocator,

    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        opts: Options,
    ) !Render {
        return .{
            .vx = try xvaxis.Vaxis.init(io, alloc, env_map, opts),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Render, writer: *std.Io.Writer) void {
        self.vx.deinit(self.alloc, writer);
    }

    pub fn window(self: *Render) Window {
        return self.vx.window();
    }

    pub fn enterAltScreen(self: *Render, writer: *std.Io.Writer) !void {
        try self.vx.enterAltScreen(writer);
    }

    pub fn exitAltScreen(self: *Render, writer: *std.Io.Writer) !void {
        try self.vx.exitAltScreen(writer);
    }

    pub fn queueRefresh(self: *Render) void {
        self.vx.queueRefresh();
    }

    pub fn resize(self: *Render, writer: *std.Io.Writer, winsize: Winsize) !void {
        self.vx.resize(self.alloc, writer, winsize) catch |err| {
            self.vx.queueRefresh();
            return err;
        };
        std.debug.assert(self.vx.screen.width == winsize.cols);
        std.debug.assert(self.vx.screen.height == winsize.rows);
    }

    /// Diff and write the screen. A write error queues a full redraw.
    pub fn render(self: *Render, writer: *std.Io.Writer) !void {
        self.vx.render(writer) catch |err| {
            self.vx.queueRefresh();
            return err;
        };
        std.debug.assert(!self.vx.refresh);
    }
};

test "init stores a 0x0 back-buffer and render writes nothing" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer r.deinit(&deinit_writer.writer);

    try std.testing.expectEqual(@as(u16, 0), r.window().width);
    try std.testing.expectEqual(@as(u16, 0), r.window().height);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "resize then draw then render emits the cell" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer r.deinit(&deinit_writer.writer);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.resize(&out.writer, .{ .rows = 1, .cols = 1, .x_pixel = 0, .y_pixel = 0 });
    out.clearRetainingCapacity();

    r.window().fill(.{ .char = .{ .grapheme = "A", .width = 1 } });
    try r.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A") != null);
}

test "a render write error forces a full redraw" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer r.deinit(&deinit_writer.writer);

    var setup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer setup.deinit();
    try r.resize(&setup.writer, .{ .rows = 1, .cols = 1, .x_pixel = 0, .y_pixel = 0 });

    r.window().fill(.{ .char = .{ .grapheme = "A", .width = 1 } });
    var fail: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, r.render(&fail));
    try std.testing.expect(r.vx.refresh);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A") != null);
}
