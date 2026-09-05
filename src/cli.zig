//! Parse the command line into one command. The parser is pure: it reads no environment,
//! writes no output, and never exits. The caller renders a diagnostic and picks the status.

const std = @import("std");

pub const usage =
    \\usage: yuke [--rpc]
;

/// One process runs one thing. `--rpc` selects the JSONL transport.
pub const Command = union(enum) {
    tui,
    /// Speak JSONL on stdin and stdout. The terminal stays free, so no view paints.
    rpc,
};

/// Name the grammar that rejected the argument. It selects the usage text.
pub const Scope = enum { root };

pub const Failure = enum {
    unknown_command,
    unknown_flag,
    missing_value,
    invalid_value,
    duplicate_flag,
};

/// `arg` and `value` borrow argv. They stay valid while the process arguments live.
pub const Diagnostic = struct {
    scope: Scope,
    failure: Failure,
    arg: []const u8,
    value: ?[]const u8 = null,
};

pub const Result = union(enum) {
    command: Command,
    help: Scope,
    diagnostic: Diagnostic,
};

/// Parse argv after the program name. The default command is the TUI.
pub fn parse(args: []const []const u8) Result {
    if (args.len == 0) return .{ .command = .tui };
    if (isFlag(args[0])) return parseRoot(args);
    return .{ .diagnostic = .{ .scope = .root, .failure = .unknown_command, .arg = args[0] } };
}

/// Each tag names one flag without the `--` prefix.
const RootFlag = enum { rpc };

fn parseRoot(args: []const []const u8) Result {
    var rpc = false;
    var seen: std.EnumSet(RootFlag) = .initEmpty();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelp(arg)) return .{ .help = .root };

        const long = splitLong(arg) orelse return fail(.root, .unknown_flag, arg);
        // No root flag takes a value.
        if (long.value != null) return fail(.root, .unknown_flag, arg);

        const flag = std.meta.stringToEnum(RootFlag, long.name[2..]) orelse return fail(.root, .unknown_flag, arg);
        if (seen.contains(flag)) return fail(.root, .duplicate_flag, long.name);
        seen.insert(flag);

        switch (flag) {
            .rpc => rpc = true,
        }
    }

    // The transport selects the command.
    return .{ .command = if (rpc) .rpc else .tui };
}

fn fail(scope: Scope, failure: Failure, arg: []const u8) Result {
    return .{ .diagnostic = .{ .scope = scope, .failure = failure, .arg = arg } };
}

/// One long option, split at the first `=`.
const Long = struct { name: []const u8, value: ?[]const u8 };

/// Split `--name` or `--name=value`. Return null for an argument that is not a long option.
fn splitLong(arg: []const u8) ?Long {
    if (!std.mem.startsWith(u8, arg, "--") or arg.len == 2) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return .{ .name = arg, .value = null };
    std.debug.assert(eq >= 2); // The `--` prefix holds no `=`.
    return .{ .name = arg[0..eq], .value = arg[eq + 1 ..] };
}

fn isFlag(arg: []const u8) bool {
    return arg.len != 0 and arg[0] == '-';
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

const testing = std.testing;

test "parse defaults to the tui" {
    try testing.expect(parse(&.{}).command == .tui);
}

test "parse selects the rpc transport" {
    try testing.expect(parse(&.{"--rpc"}).command == .rpc);
    try testing.expect(parse(&.{}).command == .tui); // no transport keeps the view
}

test "parse rejects a duplicate flag, an unknown flag, and an unknown command" {
    try testing.expectEqual(Failure.duplicate_flag, parse(&.{ "--rpc", "--rpc" }).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_flag, parse(&.{"--foo"}).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_command, parse(&.{"serve"}).diagnostic.failure);
}

test "parse reports help for the root scope" {
    try testing.expectEqual(Scope.root, parse(&.{"--help"}).help);
    try testing.expectEqual(Scope.root, parse(&.{"-h"}).help);
}
