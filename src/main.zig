//! The yuke process entry. Default mode is the TUI.

const std = @import("std");
const cli = @import("cli.zig");
const rpc = @import("app/rpc.zig");
const app = @import("app/app.zig");
const tui_app = @import("js/driver.zig");
const extensions_mod = @import("js/extensions.zig");
const auth_cli = @import("app/auth_cli.zig");
const check_cli = @import("app/check_cli.zig");
const print_cli = @import("app/print_cli.zig");
const paths = @import("paths.zig");
const engine_native = @import("js/native/engine.zig");
const proto = @import("proto");
const execution = @import("execution.zig");
const zio = @import("zio");
const build_info = @import("build_info");

pub const std_options: std.Options = .{ .logFn = logFn };

/// The TUI owns the screen, so a log line never reaches stderr there. `log_mutex` guards the log file, because a log can come from any task. Every log step runs on `std.Options.debug_io`, as `logFn` must.
var tui_mode: std.atomic.Value(bool) = .init(false);
/// `yuke check` drops each info log line, so an info line never mixes with its report.
var quiet_info: std.atomic.Value(bool) = .init(false);
var log_mutex: std.Io.Mutex = .init;
var log_file: ?std.Io.File = null;

/// Append every line to the process log, and outside the TUI also to stderr. The pid on each line tells two processes apart in the one file.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!tui_mode.load(.acquire) and !(level == .info and quiet_info.load(.acquire))) std.log.defaultLog(level, scope, format, args);
    log_mutex.lockUncancelable(std.Options.debug_io);
    defer log_mutex.unlock(std.Options.debug_io);
    const file = log_file orelse return;
    appendLog(file, "{d} [" ++ level.asText() ++ "] (" ++ @tagName(scope) ++ "): " ++ format ++ "\n", .{std.c.getpid()} ++ args);
}

/// Append one notice of the JavaScript host to the process log. Its frontend already shows it, so it never reaches stderr.
fn logNotice(level: proto.enums.NoticeLevel, source: []const u8, message: []const u8) void {
    log_mutex.lockUncancelable(std.Options.debug_io);
    defer log_mutex.unlock(std.Options.debug_io);
    const file = log_file orelse return;
    appendLog(file, "{d} [{t}] ({s}): {s}\n", .{ std.c.getpid(), level, source, message });
}

/// Append one line to `file`; a streaming writer holds the file position, so a line never lands on the line before it, and a failed write drops the rest of the line since the log is best effort.
fn appendLog(file: std.Io.File, comptime format: []const u8, args: anytype) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buf: [512]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    fw.interface.print(format, args) catch return;
    fw.interface.flush() catch {};
}

/// Open `<state>/yuke.log` for every mode. A failed open drops every later log line from the file, and stderr still gets them outside the TUI.
fn startLog(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, tui: bool) void {
    log_file = openLog(gpa, std.Options.debug_io, env) catch null;
    tui_mode.store(tui, .release);
    engine_native.notice_log = logNotice;
}

/// Close the log. A later log line reaches stderr again.
fn stopLog() void {
    const io = std.Options.debug_io;
    engine_native.notice_log = null;
    tui_mode.store(false, .release);
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);
    if (log_file) |f| f.close(io);
    log_file = null;
}

/// The log holds prompt and session text, so the file stays private to the user.
/// Every process appends with `O_APPEND`, so two processes never write over each other's lines. There is no rotation.
fn openLog(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?std.Io.File {
    const dir = (try paths.stateDir(gpa, env)) orelse return null;
    defer gpa.free(dir);
    try app.ensureDataDir(io, dir);
    const path = try std.Io.Dir.path.joinZ(gpa, &.{ dir, "yuke.log" });
    defer gpa.free(path);
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
    // Tighten a file that already existed, because the mode applies only at creation.
    std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{}) catch {};
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
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
    // The status exit runs after `run` released the reactor, so no task holds a lock at that point.
    const status = try run(init);
    if (status != 0) std.process.exit(status);
}

/// Run the command and answer the exit status.
fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len >= 1);

    const command = switch (cli.parse(args[1..])) {
        .command => |command| command,
        .help => |scope| {
            try printUsage(init.io, scope);
            return 0;
        },
        .version => {
            var buf: [64]u8 = undefined;
            var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
            try out.interface.writeAll("yuke " ++ build_info.version ++ "\n");
            try out.interface.flush();
            return 0;
        },
        .diagnostic => |diagnostic| {
            report(diagnostic);
            return 2;
        },
    };

    // One executor owns every task in this process. Both seams take its `std.Io`.
    const reactor = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer reactor.deinit();
    const io = reactor.io();

    // Every later owner reads this one environment and runs this one shell.
    const context = execution.startup(init.arena.allocator(), io, init.environ_map, .native) catch |err| {
        // Each cause has its own remedy, so none of them borrows another one's message.
        switch (err) {
            error.ShellNotFound => std.log.err("yuke: no command shell; install bash or provide {s}", .{execution.fallback_shell}),
            error.UnsupportedPlatform => std.log.err("yuke: this platform states no shell contract", .{}),
            error.OutOfMemory => unreachable,
        }
        return 1;
    };

    const tui = command == .tui;
    if (command == .check) quiet_info.store(true, .release);
    startLog(init.gpa, context.env, tui);
    defer stopLog();

    // A null directory is not an error. The baked UI still runs without a config file.
    const config_dir = try paths.configDir(init.gpa, context.env);
    defer if (config_dir) |dir| init.gpa.free(dir);
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buf);

    // Independent session trees can share this store; each tree has one engine owner.
    const application = app.App.open(init.gpa, io, context, config_dir) catch |err| {
        // This one failure has a direct operator remedy, so it names the remedy instead of the error.
        if (err == error.NoStateDirectory)
            std.log.err("yuke: no directory holds the session store; set XDG_DATA_HOME or {s}", .{paths.home_env})
        else
            std.log.err("yuke: the app did not start: {t}", .{err});
        return 1;
    };
    defer application.close();

    // The auth commands need the engine and the store, but no JavaScript host and no terminal view.
    switch (command) {
        .login => |provider| return try auth_cli.login(init.gpa, io, application, provider),
        .logout => |provider| return try auth_cli.logout(init.gpa, io, application, provider),
        .rpc, .tui, .print, .check => {},
    }

    var extensions: extensions_mod.Extensions = undefined;
    try extensions.init(init.gpa, io, application, .{
        .host = .{
            .cwd = cwd_buf[0..cwd_len],
            .execution = context,
        },
        .boot = switch (command) {
            .tui => tui_app.boot,
            .check => check_cli.boot,
            .print => print_cli.boot,
            .rpc => rpc.boot,
            .login, .logout => unreachable,
        },
        .config_dir = config_dir,
    });
    defer extensions.deinit();

    switch (command) {
        .rpc => try rpc.runIo(&extensions),
        .tui => try tui_app.runIo(&extensions),
        .print => |opts| return print_cli.run(init.gpa, io, &extensions, cwd_buf[0..cwd_len], opts),
        .check => return try check_cli.run(io, &extensions),
        .login, .logout => unreachable, // These commands return before the host starts.
    }
    return 0;
}

fn printUsage(io: std.Io, scope: cli.Scope) !void {
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("{s}\n", .{usageFor(scope)});
    try out.interface.flush();
}

fn usageFor(scope: cli.Scope) []const u8 {
    return switch (scope) {
        .root => cli.usage,
        .login => cli.login_usage,
        .logout => cli.logout_usage,
        .check => cli.check_usage,
    };
}

/// Report one rejected argument, then the usage of the grammar that rejected it.
fn report(diagnostic: cli.Diagnostic) void {
    const who = switch (diagnostic.scope) {
        .root => "yuke",
        .login => "yuke login",
        .logout => "yuke logout",
        .check => "yuke check",
    };
    switch (diagnostic.failure) {
        .unknown_command => std.log.err("{s}: unknown command '{s}'", .{ who, diagnostic.arg }),
        .unknown_flag => std.log.err("{s}: unknown option '{s}'", .{ who, diagnostic.arg }),
        .missing_value => std.log.err("{s}: {s} needs a value", .{ who, diagnostic.arg }),
        .invalid_value => std.log.err("{s}: {s} does not accept '{s}'", .{ who, diagnostic.arg, diagnostic.value.? }),
        .too_long => std.log.err("{s}: {s} takes at most {d} bytes", .{ who, diagnostic.arg, cli.max_prompt_bytes }),
        .duplicate_flag => std.log.err("{s}: {s} appears more than once", .{ who, diagnostic.arg }),
        .missing_argument => std.log.err("{s}: a provider name is needed", .{who}),
        .extra_argument => std.log.err("{s}: unexpected argument '{s}'", .{ who, diagnostic.arg }),
        .needs_print => std.log.err("{s}: {s} needs -p", .{ who, diagnostic.arg }),
        .conflict => std.log.err("{s}: {s} cannot be used with {s}", .{ who, diagnostic.arg, diagnostic.value.? }),
    }
    std.log.err("{s}", .{usageFor(diagnostic.scope)});
}
