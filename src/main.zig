//! The yuke process entry. Default mode is the TUI.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const daemon_app = @import("daemon/app.zig");
const tui_app = @import("tui/app.zig");
const paths = @import("paths/paths.zig");

pub const std_options: std.Options = .{ .logFn = logFn };

/// The TUI owns the screen, so a log line must never reach stderr. `tui_log_mutex` guards the file,
/// because a log can come from any task.
var tui_mode: std.atomic.Value(bool) = .init(false);
var tui_log_mutex: std.Io.Mutex = .init;
var tui_log: ?std.Io.File = null;

/// Write to the TUI log file in TUI mode, and to stderr in daemon mode.
/// A TUI without a log file drops the line, because stderr would damage the frame.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!tui_mode.load(.acquire)) return std.log.defaultLog(level, scope, format, args);
    tui_log_mutex.lockUncancelable(std.Options.debug_io);
    defer tui_log_mutex.unlock(std.Options.debug_io);
    const file = tui_log orelse return;
    appendLog(file, "[" ++ level.asText() ++ "] (" ++ @tagName(scope) ++ "): " ++ format ++ "\n", args);
}

/// Append one line to `file`. A streaming writer holds the file position, so a line never lands on
/// the line before it. The log is best effort, so a failed write drops the rest of the line.
fn appendLog(file: std.Io.File, comptime format: []const u8, args: anytype) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buf: [512]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    fw.interface.print(format, args) catch return;
    fw.interface.flush() catch {};
}

/// Route the TUI log to `<data>/tui.log`. A failed open discards every later TUI log message.
fn startTuiLog(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    tui_log = openTuiLog(gpa, io, env) catch null;
    tui_mode.store(true, .release);
}

/// Stop the TUI log and close the file. A later log message reaches stderr again.
fn stopTuiLog(io: std.Io) void {
    tui_mode.store(false, .release);
    tui_log_mutex.lockUncancelable(io);
    defer tui_log_mutex.unlock(io);
    if (tui_log) |f| f.close(io);
    tui_log = null;
}

/// The log holds prompt and session text, so the file stays private to the user.
fn openTuiLog(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?std.Io.File {
    const dir = (try paths.dataDir(gpa, env)) orelse return null;
    defer gpa.free(dir);
    const cwd = std.Io.Dir.cwd();
    const private = std.Io.File.Permissions.fromMode(0o700);
    if (builtin.os.tag == .windows) {
        try cwd.createDirPath(io, dir);
    } else if (try cwd.createDirPathStatus(io, dir, private) == .created) {
        try cwd.setFilePermissions(io, dir, private, .{});
    }
    const path = try std.fs.path.join(gpa, &.{ dir, "tui.log" });
    defer gpa.free(path);
    const file_private = std.Io.File.Permissions.fromMode(0o600);
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true, .permissions = file_private });
    // Tighten a file that already existed, because `createFileAbsolute` keeps its old mode.
    if (builtin.os.tag != .windows) cwd.setFilePermissions(io, path, file_private, .{}) catch {};
    return file;
}

test "appendLog keeps every line and a line over the buffer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "log.txt", .{});
    defer file.close(io);

    const long = "y" ** 900;
    appendLog(file, "one\n", .{});
    appendLog(file, "two\n", .{});
    appendLog(file, "{s}\n", .{long});

    var read = try tmp.dir.openFile(io, "log.txt", .{});
    defer read.close(io);
    var buf: [256]u8 = undefined;
    var r = read.readerStreaming(io, &buf);
    const text = try r.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);

    // A positional writer would put every line at offset zero, so the length proves the append.
    try std.testing.expectEqual(@as(usize, 8 + long.len + 1), text.len);
    try std.testing.expectEqualStrings("one\ntwo\n", text[0..8]);
    try std.testing.expectEqualStrings(long, text[8 .. 8 + long.len]);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len >= 1);
    const opts = cli.parse(args[1..]) catch |err| switch (err) {
        error.Help => {
            var buf: [128]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buf);
            try stdout.interface.print("{s}\n", .{cli.usage});
            try stdout.interface.flush();
            return;
        },
        error.Conflict => {
            std.log.err("choose one of --tui or --daemon", .{});
            std.log.err("{s}", .{cli.usage});
            std.process.exit(2);
        },
        error.UnknownFlag => {
            std.log.err("{s}", .{cli.usage});
            std.process.exit(2);
        },
    };
    switch (opts.mode) {
        .tui => {
            // A null directory is not an error. The baked UI still runs without a config file.
            const config_dir = try paths.configDir(init.gpa, init.environ_map);
            defer if (config_dir) |dir| init.gpa.free(dir);
            startTuiLog(init.gpa, init.io, init.environ_map);
            defer stopTuiLog(init.io);
            try tui_app.run(init.gpa, init.environ_map, .{
                .config_dir = config_dir,
                .safe_mode = opts.safe_mode,
            });
        },
        .daemon => try daemon_app.run(init),
    }
}
