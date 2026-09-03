const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const xvaxis = @import("xvaxis/main.zig");
const zio = @import("zio");

pub const Winsize = xvaxis.Winsize;

fn winchKind() zio.SignalKind {
    comptime std.debug.assert(@intFromEnum(posix.SIG.WINCH) <= std.math.maxInt(u8));
    return @enumFromInt(@intFromEnum(posix.SIG.WINCH));
}

/// A reactor-owned SIGWINCH watcher.
pub const WinsizeWatch = struct {
    signal: zio.Signal,

    pub fn init() !WinsizeWatch {
        return .{ .signal = try zio.Signal.init(winchKind()) };
    }

    pub fn deinit(self: *WinsizeWatch) void {
        self.signal.deinit();
        self.* = undefined;
    }

    /// Wait for SIGWINCH, then read the TTY size.
    pub fn wait(self: *WinsizeWatch, tty: *const Tty) !Winsize {
        try self.signal.wait();
        return tty.getWinsize();
    }
};

/// A raw-mode handle for the controlling TTY.
pub const Tty = struct {
    io: std.Io,
    file: std.Io.File,
    original: posix.termios,

    /// Open the controlling TTY and enter raw mode. `deinit` restores termios.
    pub fn open(io: std.Io) !Tty {
        var file = try openDevice(io);
        errdefer file.close(io);
        const original = try posix.tcgetattr(file.handle);
        try posix.tcsetattr(file.handle, .FLUSH, rawTermios(original));
        return .{ .io = io, .file = file, .original = original };
    }

    /// POSIX reads use zio cancellation.
    pub fn shutdownInput(_: *Tty) void {}

    /// Restore termios and close the TTY.
    pub fn deinit(self: *Tty) void {
        posix.tcsetattr(self.file.handle, .FLUSH, self.original) catch |err| {
            std.log.scoped(.term).err("restore terminal failed: {}", .{err});
        };
        self.file.close(self.io);
    }

    /// Read bytes. The reactor waits when no data exists.
    pub fn read(self: *Tty, buffer: []u8) !usize {
        return self.file.readStreaming(self.io, &.{buffer});
    }

    /// Build a buffered TTY writer. The caller owns the buffer.
    pub fn writerStreaming(self: *Tty, buffer: []u8) std.Io.File.Writer {
        return self.file.writerStreaming(self.io, buffer);
    }

    /// Read the TTY size with `TIOCGWINSZ`.
    pub fn getWinsize(self: *const Tty) !Winsize {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = posix.system.ioctl(self.file.handle, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
        return .{ .rows = ws.row, .cols = ws.col, .x_pixel = ws.xpixel, .y_pixel = ws.ypixel };
    }
};

/// Open the terminal device.
fn openDevice(io: std.Io) !std.Io.File {
    // `/dev/tty` fails to register with kqueue, so darwin needs the real device name
    if (builtin.os.tag.isDarwin()) {
        var buf: [posix.PATH_MAX]u8 = undefined;
        if (devicePath(&buf)) |path| {
            if (std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write })) |file| {
                return file;
            } else |_| {}
        }
    }
    return std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
}

/// Return the device path of the first standard stream that is a terminal.
fn devicePath(buf: *[posix.PATH_MAX]u8) ?[]const u8 {
    const streams = [_]posix.fd_t{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO };
    for (streams) |fd| {
        if (std.c.isatty(fd) == 0) continue;
        const rc = posix.system.fcntl(fd, posix.F.GETPATH, @intFromPtr(buf));
        if (posix.errno(rc) != .SUCCESS) continue;
        const path = std.mem.sliceTo(buf, 0);
        // A caller can redirect a standard stream from `/dev/tty`; that name is the one to avoid.
        if (!std.fs.path.isAbsolute(path) or std.mem.eql(u8, path, "/dev/tty")) continue;
        return path;
    }
    return null;
}

/// Build raw-mode termios from the saved state. Clear echo, canonical, and transform flags.
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

test "WinsizeWatch waits for SIGWINCH" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var watch = try WinsizeWatch.init();
    defer watch.deinit();

    const Wait = struct {
        fn run(w: *WinsizeWatch, done: *bool) !void {
            try w.signal.wait();
            done.* = true;
        }
    };
    const Send = struct {
        fn run(r: *zio.Runtime) !void {
            try r.sleep(.fromMilliseconds(10));
            try posix.raise(posix.SIG.WINCH);
        }
    };

    var done = false;
    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(Wait.run, .{ &watch, &done });
    try group.spawn(Send.run, .{rt});
    try group.wait();
    try std.testing.expect(done);
}
