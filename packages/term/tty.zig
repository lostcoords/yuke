const std = @import("std");
const posix = std.posix;
const vaxis = @import("vaxis");

pub const Winsize = vaxis.Winsize;

/// A raw-mode handle to the controlling terminal. It reads and writes through
/// the reactor io.
pub const Tty = struct {
    io: std.Io,
    file: std.Io.File,
    original: posix.termios,

    /// Open the /dev/tty device and enter raw mode. The deinit call restores the
    /// saved termios.
    pub fn open(io: std.Io) !Tty {
        var file = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        errdefer file.close(io);
        const original = try posix.tcgetattr(file.handle);
        try posix.tcsetattr(file.handle, .FLUSH, rawTermios(original));
        return .{ .io = io, .file = file, .original = original };
    }

    /// Restore the saved termios and close the terminal.
    pub fn deinit(self: *Tty) void {
        posix.tcsetattr(self.file.handle, .FLUSH, self.original) catch |err| {
            std.log.scoped(.term).err("restore terminal failed: {}", .{err});
        };
        self.file.close(self.io);
    }

    /// Read bytes into the buffer. The reactor suspends the task when the read
    /// has no data.
    pub fn read(self: *Tty, buffer: []u8) !usize {
        return self.file.readStreaming(self.io, &.{buffer});
    }

    /// Build a buffered writer over the terminal. The caller owns the buffer.
    pub fn writerStreaming(self: *Tty, buffer: []u8) std.Io.File.Writer {
        return self.file.writerStreaming(self.io, buffer);
    }

    /// Read the terminal size with the TIOCGWINSZ ioctl.
    pub fn getWinsize(self: *const Tty) !Winsize {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = posix.system.ioctl(self.file.handle, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
        return .{ .rows = ws.row, .cols = ws.col, .x_pixel = ws.xpixel, .y_pixel = ws.ypixel };
    }
};

/// Compute the raw-mode termios from the saved state. It clears the echo,
/// canonical, and transform flags.
fn rawTermios(state: posix.termios) posix.termios {
    var raw = state;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    return raw;
}

test "rawTermios clears echo and canonical flags" {
    var state: posix.termios = std.mem.zeroes(posix.termios);
    state.lflag.ECHO = true;
    state.lflag.ICANON = true;
    state.lflag.ISIG = true;
    state.iflag.ICRNL = true;
    state.oflag.OPOST = true;

    const raw = rawTermios(state);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.oflag.OPOST);
    try std.testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(posix.V.TIME)]);
}
