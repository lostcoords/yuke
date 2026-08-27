const std = @import("std");

pub const usage = "usage: yuke [--tui | --daemon] [--safe-mode]";

pub const Mode = enum { tui, daemon };

pub const Cli = struct {
    mode: Mode = .tui,
    /// Skip the user entry file. The daemon ignores this flag.
    safe_mode: bool = false,
};

pub const ParseError = error{
    Help,
    Conflict,
    UnknownFlag,
};

/// Parse argv after the program name. Default mode is the TUI.
pub fn parse(args: []const []const u8) ParseError!Cli {
    var out: Cli = .{};
    var mode: ?Mode = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--tui")) {
            if (mode == .daemon) return error.Conflict;
            mode = .tui;
        } else if (std.mem.eql(u8, arg, "--daemon")) {
            if (mode == .tui) return error.Conflict;
            mode = .daemon;
        } else if (std.mem.eql(u8, arg, "--safe-mode")) {
            out.safe_mode = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else {
            return error.UnknownFlag;
        }
    }
    out.mode = mode orelse .tui;
    return out;
}

test "parse defaults to tui" {
    try std.testing.expectEqual(Mode.tui, (try parse(&.{})).mode);
    try std.testing.expectEqual(Mode.tui, (try parse(&.{"--tui"})).mode);
    try std.testing.expectEqual(Mode.daemon, (try parse(&.{"--daemon"})).mode);
}

test "parse reads safe mode and keeps the default off" {
    try std.testing.expect(!(try parse(&.{"--tui"})).safe_mode);
    try std.testing.expect((try parse(&.{"--safe-mode"})).safe_mode);
    try std.testing.expectEqual(Mode.tui, (try parse(&.{"--safe-mode"})).mode);
}

test "parse rejects a conflict and an unknown flag" {
    try std.testing.expectError(error.Conflict, parse(&.{ "--tui", "--daemon" }));
    try std.testing.expectError(error.Conflict, parse(&.{ "--daemon", "--tui" }));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--foo"}));
    try std.testing.expectError(error.Help, parse(&.{"--help"}));
    try std.testing.expectError(error.Help, parse(&.{"-h"}));
}
