const std = @import("std");
const xvaxis = @import("xvaxis/main.zig");

pub const Options = xvaxis.Vaxis.Options;
pub const Window = xvaxis.Window;
pub const Winsize = xvaxis.Winsize;

/// A frame transaction over xvaxis. The caller owns the writer and environment.
pub const Render = struct {
    vx: xvaxis.Vaxis,
    alloc: std.mem.Allocator,
    /// True inside tmux. A clipboard write then needs the passthrough sequence.
    tmux: bool,

    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        opts: Options,
    ) !Render {
        return .{
            .vx = try xvaxis.Vaxis.init(io, alloc, env_map, opts),
            .alloc = alloc,
            .tmux = env_map.get("TMUX") != null,
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

    /// Turn bracketed paste on or off. The terminal wraps pasted text in markers.
    /// `deinit` tries to turn the mode off again.
    pub fn setBracketedPaste(self: *Render, writer: *std.Io.Writer, enable: bool) !void {
        try self.vx.setBracketedPaste(writer, enable);
    }

    /// Turn mouse reporting on or off. The mode reports clicks, drags, the wheel, and focus.
    /// `deinit` turns the mode off again.
    pub fn setMouseMode(self: *Render, writer: *std.Io.Writer, enable: bool) !void {
        try self.vx.setMouseMode(writer, enable);
    }

    /// Limit the raw OSC 52 payload. Reject larger text instead of truncation.
    pub const clipboard_max = 100 * 1000;

    /// OSC 52 inside a tmux passthrough. Each inner escape is doubled, and the payload ends with
    /// BEL, so the tail needs no second doubled escape.
    const tmux_clipboard_copy = "\x1bPtmux;\x1b\x1b]52;c;{s}\x07\x1b\\";

    /// Ask the terminal to set the system clipboard through OSC 52.
    /// The sequence has no acknowledgement, so a success means only that the write left this process.
    pub fn copyToClipboard(self: *Render, writer: *std.Io.Writer, text: []const u8) !void {
        if (text.len > clipboard_max) return error.ClipboardTooLarge;
        const encoder = std.base64.standard.Encoder;
        const buf = try self.alloc.alloc(u8, encoder.calcSize(text.len));
        defer self.alloc.free(buf);
        const b64 = encoder.encode(buf, text);

        try writer.print(xvaxis.ctlseqs.osc52_clipboard_copy, .{b64});
        // tmux with `set-clipboard external` drops an application OSC 52. The passthrough carries
        // the same sequence to the outer terminal, which owns the real clipboard.
        if (self.tmux) try writer.print(tmux_clipboard_copy, .{b64});
        try writer.flush();
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

test "bracketed paste sets the mode and deinit resets it" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    {
        var r = try Render.init(io, std.testing.allocator, &env_map, .{});
        defer r.deinit(&out.writer);

        try r.setBracketedPaste(&out.writer, true);
        try std.testing.expectEqualStrings("\x1b[?2004h", out.written());
        out.clearRetainingCapacity();
    }

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[?2004l") != null);
}

test "mouse mode sets 1002;1004;1006 and deinit resets it" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    {
        var r = try Render.init(io, std.testing.allocator, &env_map, .{});
        defer r.deinit(&out.writer);

        try r.setMouseMode(&out.writer, true);
        // Mode 1003 must stay out, so the terminal never reports hover motion.
        try std.testing.expectEqualStrings("\x1b[?1002;1004;1006h", out.written());
        out.clearRetainingCapacity();
    }

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[?1002;1003;1004;1006;1016l") != null);
}

test "a mouse disable stops deinit from resetting the mode twice" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    try r.setMouseMode(&out.writer, true);
    try r.setMouseMode(&out.writer, false);
    out.clearRetainingCapacity();

    r.deinit(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "1002") == null);
}

test "copyToClipboard emits base64 OSC 52 and refuses an oversize payload" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    // The test inherits the real environment, so drop TMUX to test the plain sequence alone.
    _ = env_map.swapRemove("TMUX");

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    defer r.deinit(&out.writer);

    try r.copyToClipboard(&out.writer, "hello");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", out.written());

    const big = try std.testing.allocator.alloc(u8, Render.clipboard_max + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try std.testing.expectError(error.ClipboardTooLarge, r.copyToClipboard(&out.writer, big));
}

test "a tmux session also gets the passthrough clipboard sequence" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TMUX", "/tmp/tmux-501/default,123,0");

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    defer r.deinit(&out.writer);
    try std.testing.expect(r.tmux);

    try r.copyToClipboard(&out.writer, "hi");
    // The plain sequence serves `set-clipboard on`. The passthrough serves `external`.
    try std.testing.expectEqualStrings(
        "\x1b]52;c;aGk=\x1b\\" ++ "\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\",
        out.written(),
    );
}

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
