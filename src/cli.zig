const std = @import("std");

pub const usage = "usage: yuke [--tui | --daemon]";

pub const Mode = enum { tui, daemon };

pub const ParseError = error{
    Help,
    Conflict,
    UnknownFlag,
};

/// Parse argv after the program name. Default mode is the TUI.
pub fn parseMode(args: []const []const u8) ParseError!Mode {
    var mode: ?Mode = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--tui")) {
            if (mode == .daemon) return error.Conflict;
            mode = .tui;
        } else if (std.mem.eql(u8, arg, "--daemon")) {
            if (mode == .tui) return error.Conflict;
            mode = .daemon;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else {
            return error.UnknownFlag;
        }
    }
    return mode orelse .tui;
}

test "parseMode defaults to tui" {
    try std.testing.expectEqual(Mode.tui, try parseMode(&.{}));
    try std.testing.expectEqual(Mode.tui, try parseMode(&.{"--tui"}));
    try std.testing.expectEqual(Mode.daemon, try parseMode(&.{"--daemon"}));
}

test "parseMode rejects a conflict and an unknown flag" {
    try std.testing.expectError(error.Conflict, parseMode(&.{ "--tui", "--daemon" }));
    try std.testing.expectError(error.Conflict, parseMode(&.{ "--daemon", "--tui" }));
    try std.testing.expectError(error.UnknownFlag, parseMode(&.{"--foo"}));
    try std.testing.expectError(error.Help, parseMode(&.{"--help"}));
    try std.testing.expectError(error.Help, parseMode(&.{"-h"}));
}
