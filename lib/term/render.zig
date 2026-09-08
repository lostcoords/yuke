const std = @import("std");
const xvaxis = @import("xvaxis/main.zig");

pub const Options = xvaxis.Vaxis.Options;
pub const Window = xvaxis.Window;
pub const Winsize = xvaxis.Winsize;

/// A frame transaction over xvaxis. The caller owns the writer and environment.
pub const Render = struct {
    vx: xvaxis.Vaxis,
    alloc: std.mem.Allocator,
    glyphs: std.heap.ArenaAllocator,
    frame: enum { idle, open, pending } = .idle,
    /// True inside tmux. A clipboard write then needs the passthrough sequence.
    tmux: bool,

    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        opts: Options,
    ) !Render {
        var vx = try xvaxis.Vaxis.init(io, alloc, env_map, opts);
        vx.caps.unicode = .unicode;
        vx.screen.width_method = .unicode;
        return .{
            .vx = vx,
            .alloc = alloc,
            .glyphs = .init(alloc),
            .tmux = env_map.get("TMUX") != null,
        };
    }

    pub fn deinit(self: *Render, writer: *std.Io.Writer) void {
        self.vx.deinit(self.alloc, writer);
        self.glyphs.deinit();
    }

    pub fn window(self: *Render) Window {
        return self.vx.window();
    }

    pub fn beginFrame(self: *Render) void {
        self.window().clear();
        self.window().hideCursor();
        _ = self.glyphs.reset(.retain_capacity);
        self.frame = .open;
    }

    pub fn ensureFrame(self: *Render) bool {
        if (self.frame == .open) return false;
        self.beginFrame();
        return true;
    }

    /// The grid borrows this text until the next frame or resize.
    pub fn writeText(self: *Render, win: Window, text: []const u8, style: xvaxis.Style) !void {
        std.debug.assert(win.screen == &self.vx.screen);
        const copy = try self.glyphs.allocator().dupe(u8, text);
        _ = win.printSegment(.{ .text = copy, .style = style }, .{ .wrap = .none });
    }

    /// An idle frame does no work; a failed commit retains the text for retry.
    pub fn commitFrame(self: *Render, writer: *std.Io.Writer) !bool {
        if (self.frame == .idle) return false;
        try self.render(writer);
        return true;
    }

    pub fn enterAltScreen(self: *Render, writer: *std.Io.Writer) !void {
        try self.vx.enterAltScreen(writer);
    }

    pub fn exitAltScreen(self: *Render, writer: *std.Io.Writer) !void {
        try self.vx.exitAltScreen(writer);
    }

    /// Set bracketed paste; deinit resets the mode.
    pub fn setBracketedPaste(self: *Render, writer: *std.Io.Writer, enable: bool) !void {
        try self.vx.setBracketedPaste(writer, enable);
    }

    /// Set mouse and focus reports; deinit resets the mode.
    pub fn setMouseMode(self: *Render, writer: *std.Io.Writer, enable: bool) !void {
        try self.vx.setMouseMode(writer, enable);
    }

    /// Limit the raw OSC 52 payload. Reject larger text instead of truncation.
    pub const clipboard_max = 100 * 1000;

    /// The tmux passthrough doubles each inner escape and ends the OSC payload with BEL.
    const tmux_clipboard_copy = "\x1bPtmux;\x1b\x1b]52;c;{s}\x07\x1b\\";

    /// Send OSC 52; the terminal provides no acknowledgement.
    pub fn copyToClipboard(self: *Render, writer: *std.Io.Writer, text: []const u8) !void {
        if (text.len > clipboard_max) return error.ClipboardTooLarge;
        const encoder = std.base64.standard.Encoder;
        const buf = try self.alloc.alloc(u8, encoder.calcSize(text.len));
        defer self.alloc.free(buf);
        const b64 = encoder.encode(buf, text);

        try writer.print(xvaxis.ctlseqs.osc52_clipboard_copy, .{b64});
        // The passthrough serves the outer terminal when tmux uses `set-clipboard external`.
        if (self.tmux) try writer.print(tmux_clipboard_copy, .{b64});
        try writer.flush();
    }

    pub fn queueRefresh(self: *Render) void {
        self.vx.queueRefresh();
    }

    pub fn resize(self: *Render, writer: *std.Io.Writer, winsize: Winsize) !void {
        self.vx.resize(self.alloc, writer, winsize) catch |err| {
            self.vx.queueRefresh();
            // A write failure occurs after Vaxis replaces both grids.
            if (err == error.WriteFailed) {
                _ = self.glyphs.reset(.retain_capacity);
                self.frame = .pending;
            }
            return err;
        };
        _ = self.glyphs.reset(.retain_capacity);
        self.frame = .idle;
        std.debug.assert(self.vx.screen.width == winsize.cols);
        std.debug.assert(self.vx.screen.height == winsize.rows);
    }

    /// Diff and write the screen. A write error queues a full redraw.
    pub fn render(self: *Render, writer: *std.Io.Writer) !void {
        self.vx.render(writer) catch |err| {
            self.vx.queueRefresh();
            if (self.frame == .idle) self.frame = .pending;
            return err;
        };
        self.frame = .idle;
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

    var alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var r = try Render.init(io, alloc.allocator(), &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer r.deinit(&deinit_writer.writer);

    var setup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer setup.deinit();
    try r.resize(&setup.writer, .{ .rows = 1, .cols = 1, .x_pixel = 0, .y_pixel = 0 });

    r.beginFrame();
    var text = [_]u8{'A'};
    try r.writeText(r.window(), &text, .{});
    text[0] = 'Z';
    alloc.fail_index = alloc.alloc_index;
    try std.testing.expectError(error.OutOfMemory, r.resize(&setup.writer, .{ .rows = 2, .cols = 2, .x_pixel = 0, .y_pixel = 0 }));
    alloc.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(.open, r.frame);
    var fail: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, r.commitFrame(&fail));
    try std.testing.expect(r.vx.refresh);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try r.commitFrame(&out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A") != null);
    try std.testing.expect(!try r.commitFrame(&out.writer));
}

test "a repeat render of the same screen with a visible cursor writes nothing" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer r.deinit(&deinit_writer.writer);

    var setup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer setup.deinit();
    try r.resize(&setup.writer, .{ .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0 });

    // A visible cursor must not force the render preamble when the cells stay unchanged.
    const win = r.window();
    win.fill(.{ .char = .{ .grapheme = "A", .width = 1 } });
    win.showCursor(1, 1);

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try r.render(&first.writer);
    try std.testing.expect(first.written().len > 0);

    win.fill(.{ .char = .{ .grapheme = "A", .width = 1 } });
    win.showCursor(1, 1);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try r.render(&second.writer);
    try std.testing.expectEqual(@as(usize, 0), second.written().len);
}

test "a secondary cursor list is freed after a reset" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var r = try Render.init(io, std.testing.allocator, &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer r.deinit(&deinit_writer.writer);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.resize(&out.writer, .{ .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0 });

    r.vx.caps.multi_cursor = true;
    const win = r.window();
    win.fill(.{ .char = .{ .grapheme = "A", .width = 1 } });
    win.showCursor(0, 0);

    // A render adopts the list, so the reset after it must free the copy the state still owns.
    try r.vx.addTerminalSecondaryCursor(std.testing.allocator, 1, 1);
    try r.render(&out.writer);
    try r.vx.resetAllTerminalSecondaryCursors(std.testing.allocator);

    // A second list over the first must not leak the one the state replaced.
    try r.vx.addTerminalSecondaryCursor(std.testing.allocator, 1, 1);
    try r.render(&out.writer);
    try r.vx.addTerminalSecondaryCursor(std.testing.allocator, 0, 2);
    try r.render(&out.writer);
}
