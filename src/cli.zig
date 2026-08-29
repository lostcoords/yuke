//! Parse the command line into one command. The parser is pure: it reads no environment,
//! writes no output, and never exits. The caller renders a diagnostic and picks the status.

const std = @import("std");

pub const usage =
    \\usage: yuke [--tui | --daemon] [--safe-mode]
    \\       yuke login [options]
;

pub const login_usage =
    \\usage: yuke login [--role daemon|client|both] [--kind cli|token]
    \\                  [--name NAME] [--cloud URL] [--force]
;

/// Select the principals that one enrollment creates.
pub const Role = enum { daemon, client, both };

/// Select the credential shape of a client session.
pub const SessionKind = enum { cli, token };

pub const Root = struct {
    /// Skip the user entry file. The daemon ignores this flag.
    safe_mode: bool = false,
};

/// A null field takes its value later from the terminal, the environment, or a default.
pub const Login = struct {
    role: ?Role = null,
    kind: SessionKind = .cli,
    name: ?[]const u8 = null,
    cloud: ?[]const u8 = null,
    force: bool = false,
};

pub const Command = union(enum) {
    tui: Root,
    daemon: Root,
    login: Login,
};

/// Name the grammar that rejected the argument. It selects the usage text.
pub const Scope = enum { root, login };

pub const Failure = enum {
    unknown_command,
    unknown_flag,
    missing_value,
    invalid_value,
    duplicate_flag,
    mode_conflict,
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
    if (args.len == 0) return .{ .command = .{ .tui = .{} } };
    if (std.mem.eql(u8, args[0], "login")) return parseLogin(args[1..]);
    if (isFlag(args[0])) return parseRoot(args);
    return .{ .diagnostic = .{ .scope = .root, .failure = .unknown_command, .arg = args[0] } };
}

/// Each tag names one flag without the `--` prefix.
const RootFlag = enum { tui, daemon, @"safe-mode" };

fn parseRoot(args: []const []const u8) Result {
    var out: Root = .{};
    var mode: ?std.meta.Tag(Command) = null;
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
            .tui, .daemon => {
                const want: std.meta.Tag(Command) = if (flag == .tui) .tui else .daemon;
                if (mode) |held| if (held != want) return fail(.root, .mode_conflict, arg);
                mode = want;
            },
            .@"safe-mode" => out.safe_mode = true,
        }
    }

    return .{
        .command = switch (mode orelse .tui) {
            .tui => .{ .tui = out },
            .daemon => .{ .daemon = out },
            .login => unreachable, // A root flag never selects the login command.
        },
    };
}

const LoginFlag = enum { role, kind, name, cloud, force };

fn parseLogin(args: []const []const u8) Result {
    var out: Login = .{};
    var seen: std.EnumSet(LoginFlag) = .initEmpty();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelp(arg)) return .{ .help = .login };

        const long = splitLong(arg) orelse return fail(.login, .unknown_flag, arg);
        const flag = std.meta.stringToEnum(LoginFlag, long.name[2..]) orelse return fail(.login, .unknown_flag, arg);
        if (seen.contains(flag)) return fail(.login, .duplicate_flag, long.name);
        seen.insert(flag);

        if (flag == .force) {
            if (long.value != null) return fail(.login, .unknown_flag, arg);
            out.force = true;
            continue;
        }

        const value = takeValue(args, &i, long) orelse return fail(.login, .missing_value, long.name);

        switch (flag) {
            .role => out.role = std.meta.stringToEnum(Role, value) orelse return invalid(long.name, value),
            .kind => out.kind = std.meta.stringToEnum(SessionKind, value) orelse return invalid(long.name, value),
            .name => out.name = value,
            .cloud => out.cloud = value,
            .force => unreachable, // The force flag returns above.
        }
    }

    return .{ .command = .{ .login = out } };
}

fn fail(scope: Scope, failure: Failure, arg: []const u8) Result {
    return .{ .diagnostic = .{ .scope = scope, .failure = failure, .arg = arg } };
}

fn invalid(arg: []const u8, value: []const u8) Result {
    return .{ .diagnostic = .{ .scope = .login, .failure = .invalid_value, .arg = arg, .value = value } };
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

/// Take the value of `long`, either after `=` or from the next argument.
/// An empty inline value, an absent argument, or another flag gives null.
fn takeValue(args: []const []const u8, i: *usize, long: Long) ?[]const u8 {
    if (long.value) |value| return if (value.len == 0) null else value;
    if (i.* + 1 >= args.len) return null;
    const next = args[i.* + 1];
    if (isFlag(next)) return null;
    i.* += 1;
    return next;
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
    try testing.expect(parse(&.{"--tui"}).command == .tui);
    try testing.expect(parse(&.{"--daemon"}).command == .daemon);
}

test "parse reads safe mode and keeps the default off" {
    try testing.expect(!parse(&.{"--tui"}).command.tui.safe_mode);
    try testing.expect(parse(&.{"--safe-mode"}).command.tui.safe_mode);
    try testing.expect(parse(&.{ "--daemon", "--safe-mode" }).command.daemon.safe_mode);
}

test "parse rejects a conflict, a duplicate, and an unknown flag" {
    try testing.expectEqual(Failure.mode_conflict, parse(&.{ "--tui", "--daemon" }).diagnostic.failure);
    try testing.expectEqual(Failure.duplicate_flag, parse(&.{ "--tui", "--tui" }).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_flag, parse(&.{"--foo"}).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_command, parse(&.{"serve"}).diagnostic.failure);
}

test "parse reports help for both scopes" {
    try testing.expectEqual(Scope.root, parse(&.{"--help"}).help);
    try testing.expectEqual(Scope.root, parse(&.{"-h"}).help);
    try testing.expectEqual(Scope.login, parse(&.{ "login", "--help" }).help);
}

test "login takes both value forms" {
    const spaced = parse(&.{ "login", "--role", "both", "--kind", "token" }).command.login;
    try testing.expectEqual(Role.both, spaced.role.?);
    try testing.expectEqual(SessionKind.token, spaced.kind);

    const inlined = parse(&.{ "login", "--role=daemon", "--name=ci-box" }).command.login;
    try testing.expectEqual(Role.daemon, inlined.role.?);
    try testing.expectEqualStrings("ci-box", inlined.name.?);
}

test "login leaves the role and the name unset by default" {
    const out = parse(&.{"login"}).command.login;
    try testing.expect(out.role == null);
    try testing.expect(out.name == null);
    try testing.expect(out.cloud == null);
    try testing.expectEqual(SessionKind.cli, out.kind);
    try testing.expect(!out.force);
}

test "login carries the offending value on a bad enum" {
    const d = parse(&.{ "login", "--role", "worker" }).diagnostic;
    try testing.expectEqual(Failure.invalid_value, d.failure);
    try testing.expectEqualStrings("--role", d.arg);
    try testing.expectEqualStrings("worker", d.value.?);
}

test "login rejects a value that is absent, empty, or another flag" {
    try testing.expectEqual(Failure.missing_value, parse(&.{ "login", "--role" }).diagnostic.failure);
    try testing.expectEqual(Failure.missing_value, parse(&.{ "login", "--name=" }).diagnostic.failure);
    try testing.expectEqual(Failure.missing_value, parse(&.{ "login", "--name", "--force" }).diagnostic.failure);
}

test "login rejects a value on the force flag and a duplicate flag" {
    try testing.expectEqual(Failure.unknown_flag, parse(&.{ "login", "--force=yes" }).diagnostic.failure);
    try testing.expectEqual(Failure.duplicate_flag, parse(&.{ "login", "--force", "--force" }).diagnostic.failure);
}

test "login keeps a value that starts with a dash in the inline form" {
    const out = parse(&.{ "login", "--name=-box" }).command.login;
    try testing.expectEqualStrings("-box", out.name.?);
}
