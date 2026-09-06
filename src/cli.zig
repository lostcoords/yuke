//! Parse argv into one command with no side effects. The caller renders a diagnostic and picks the status.

const std = @import("std");
const proto = @import("proto");

pub const usage =
    \\usage: yuke [--rpc]
    \\       yuke -p [prompt] [--json] [--model <m>] [--reasoning <r>] [--session <id> | -c]
    \\       yuke login [provider]
    \\       yuke logout <provider>
;
pub const login_usage =
    \\usage: yuke login [provider]
;
pub const logout_usage =
    \\usage: yuke logout <provider>
;

/// One process runs one thing. `--rpc` selects the JSONL transport.
pub const Command = union(enum) {
    tui,
    /// Speak JSONL on stdin and stdout. The terminal stays free, so no view paints.
    rpc,
    /// Run one turn without a view, print the reply, and exit with the outcome.
    print: Print,
    /// Sign in to one provider, or list every provider when the name is absent.
    login: ?[]const u8,
    /// Drop the credential of one provider.
    logout: []const u8,
};

/// A print run uses this session. `new` opens a session in the working directory.
pub const Target = union(enum) {
    new,
    /// Use the newest session of the working directory.
    @"continue",
    /// Use one session by id. The text is a valid wire id.
    session: []const u8,
};

/// Every slice borrows argv.
pub const Print = struct {
    /// The prompt to send. A null value reads it from stdin.
    prompt: ?[]const u8 = null,
    json: bool = false,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    target: Target = .new,
};

/// Name the grammar that rejected the argument. It selects the usage text.
pub const Scope = enum { root, login, logout };

pub const Failure = enum {
    unknown_command,
    unknown_flag,
    missing_value,
    invalid_value,
    duplicate_flag,
    missing_argument,
    extra_argument,
    /// `arg` needs `-p`.
    needs_print,
    /// `arg` and `value` exclude each other.
    conflict,
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
    const sub = std.meta.stringToEnum(Subcommand, args[0]) orelse return fail(.root, .unknown_command, args[0]);
    return switch (sub) {
        .login => parseName(.login, args[1..]),
        .logout => parseName(.logout, args[1..]),
    };
}

const Subcommand = enum { login, logout };

/// Parse `[provider]` for login, `<provider>` for logout. Neither takes a flag.
fn parseName(scope: Scope, args: []const []const u8) Result {
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (isHelp(arg)) return .{ .help = scope };
        if (isFlag(arg)) return fail(scope, .unknown_flag, arg);
        if (name != null) return fail(scope, .extra_argument, arg);
        name = arg;
    }
    return switch (scope) {
        .login => .{ .command = .{ .login = name } },
        .logout => .{ .command = .{ .logout = name orelse return fail(.logout, .missing_argument, "logout") } },
        .root => unreachable,
    };
}

/// Each tag names one root option without the `--` prefix. `specs` holds its spelling and arity.
const RootFlag = enum { rpc, print, json, model, reasoning, session, @"continue" };

/// A root option has a short spelling, or 0 for none, and it can take a value.
const Spec = struct { short: u8 = 0, value: bool = false };

const specs: std.EnumArray(RootFlag, Spec) = .init(.{
    .rpc = .{},
    .print = .{ .short = 'p' },
    .json = .{},
    .model = .{ .value = true },
    .reasoning = .{ .value = true },
    .session = .{ .value = true },
    .@"continue" = .{ .short = 'c' },
});

/// Return the spelling of a flag for a diagnostic. The short form takes priority when one exists.
fn flagName(flag: RootFlag) []const u8 {
    switch (flag) {
        inline else => |tag| {
            const spec = comptime specs.get(tag);
            return if (spec.short != 0) "-" ++ .{spec.short} else "--" ++ @tagName(tag);
        },
    }
}

/// Return the flag for `-x`, or null for an argument that is not a short option.
fn shortFlag(arg: []const u8) ?RootFlag {
    if (arg.len != 2 or arg[0] != '-') return null;
    for (std.enums.values(RootFlag)) |flag| if (specs.get(flag).short == arg[1]) return flag;
    return null;
}

fn parseRoot(args: []const []const u8) Result {
    var print: Print = .{};
    var seen: std.EnumSet(RootFlag) = .initEmpty();
    var prompt: ?[]const u8 = null;
    var literal = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (literal or !isFlag(arg)) {
            if (prompt != null) return fail(.root, .extra_argument, arg);
            prompt = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }
        if (isHelp(arg)) return .{ .help = .root };

        var value: ?[]const u8 = null;
        var name = arg;
        const flag = shortFlag(arg) orelse blk: {
            const long = splitLong(arg) orelse return fail(.root, .unknown_flag, arg);
            value = long.value;
            name = long.name;
            break :blk std.meta.stringToEnum(RootFlag, long.name[2..]) orelse return fail(.root, .unknown_flag, arg);
        };
        if (seen.contains(flag)) return fail(.root, .duplicate_flag, name);
        seen.insert(flag);

        if (specs.get(flag).value) {
            if (value == null) {
                i += 1;
                if (i == args.len) return fail(.root, .missing_value, name);
                value = args[i];
            }
        } else if (value != null) return fail(.root, .unknown_flag, arg);

        switch (flag) {
            .rpc, .print => {},
            .json => print.json = true,
            .model => print.model = value.?,
            .reasoning => print.reasoning = value.?,
            .session => print.target = .{ .session = value.? },
            .@"continue" => print.target = .@"continue",
        }
    }

    if (!seen.contains(.print)) {
        // Every other flag and the prompt describe a print run.
        var it = seen.iterator();
        while (it.next()) |flag| if (flag != .rpc) return fail(.root, .needs_print, flagName(flag));
        if (prompt) |p| return fail(.root, .extra_argument, p);
        return .{ .command = if (seen.contains(.rpc)) .rpc else .tui };
    }
    if (seen.contains(.rpc)) return conflict("--rpc", "-p");
    if (seen.contains(.session) and seen.contains(.@"continue")) return conflict("--session", "-c");
    // A resumed session keeps its own model and level.
    if (print.target != .new) {
        const target = if (print.target == .session) "--session" else "-c";
        if (seen.contains(.model)) return conflict("--model", target);
        if (seen.contains(.reasoning)) return conflict("--reasoning", target);
    }
    if (print.target == .session and !proto.ids.SessionId.validText(print.target.session)) {
        return .{ .diagnostic = .{ .scope = .root, .failure = .invalid_value, .arg = "--session", .value = print.target.session } };
    }
    print.prompt = prompt;
    return .{ .command = .{ .print = print } };
}

fn fail(scope: Scope, failure: Failure, arg: []const u8) Result {
    return .{ .diagnostic = .{ .scope = scope, .failure = failure, .arg = arg } };
}

fn conflict(arg: []const u8, other: []const u8) Result {
    return .{ .diagnostic = .{ .scope = .root, .failure = .conflict, .arg = arg, .value = other } };
}

/// A long option splits at the first `=`.
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
}

test "parse rejects a duplicate flag, an unknown flag, and an unknown command" {
    try testing.expectEqual(Failure.duplicate_flag, parse(&.{ "--rpc", "--rpc" }).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_flag, parse(&.{"--foo"}).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_flag, parse(&.{"--rpc=1"}).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_command, parse(&.{"serve"}).diagnostic.failure);
}

test "parse reports help for the root scope" {
    try testing.expectEqual(Scope.root, parse(&.{"--help"}).help);
    try testing.expectEqual(Scope.root, parse(&.{"-h"}).help);
}

test "parse reads login with an optional name and logout with a required one" {
    try testing.expect(parse(&.{"login"}).command.login == null);
    try testing.expectEqualStrings("codex", parse(&.{ "login", "codex" }).command.login.?);
    try testing.expectEqualStrings("codex", parse(&.{ "logout", "codex" }).command.logout);
    try testing.expectEqual(Failure.missing_argument, parse(&.{"logout"}).diagnostic.failure);
    try testing.expectEqual(Failure.extra_argument, parse(&.{ "login", "a", "b" }).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_flag, parse(&.{ "login", "--key" }).diagnostic.failure);
    try testing.expectEqual(Scope.login, parse(&.{ "login", "--help" }).help);
    try testing.expectEqual(Scope.logout, parse(&.{ "logout", "-h" }).help);
}

test "parse reads a print run with its prompt, flags, and values" {
    const bare = parse(&.{"-p"}).command.print;
    try testing.expect(bare.prompt == null); // A null prompt reads from stdin.
    try testing.expect(!bare.json);
    try testing.expect(bare.target == .new);

    const full = parse(&.{ "--json", "-p", "hi", "--model=m", "--reasoning", "r" }).command.print;
    try testing.expectEqualStrings("hi", full.prompt.?);
    try testing.expect(full.json);
    try testing.expectEqualStrings("m", full.model.?);
    try testing.expectEqualStrings("r", full.reasoning.?);

    // A prompt that starts with a dash follows the terminator.
    try testing.expectEqualStrings("-x", parse(&.{ "-p", "--", "-x" }).command.print.prompt.?);
    try testing.expectEqualStrings("--json", parse(&.{ "-p", "--", "--json" }).command.print.prompt.?);

    try testing.expectEqual(Scope.root, parse(&.{ "-p", "-h" }).help);
    try testing.expectEqual(Failure.extra_argument, parse(&.{ "--print", "a", "b" }).diagnostic.failure);
    try testing.expectEqual(Failure.missing_value, parse(&.{ "-p", "--model" }).diagnostic.failure);
    try testing.expectEqual(Failure.duplicate_flag, parse(&.{ "-p", "--print" }).diagnostic.failure);
    try testing.expectEqual(Failure.unknown_flag, parse(&.{ "-p", "-x" }).diagnostic.failure);
}

test "parse picks the print target and rejects the pairs that exclude each other" {
    const id = "0123456789abcdef0123456789abcdef";
    try testing.expectEqualStrings(id, parse(&.{ "-p", "--session", id }).command.print.target.session);
    try testing.expect(parse(&.{ "-c", "-p" }).command.print.target == .@"continue");

    const bad = parse(&.{ "-p", "--session", "nope" }).diagnostic;
    try testing.expectEqual(Failure.invalid_value, bad.failure);
    try testing.expectEqualStrings("nope", bad.value.?);

    const pair = parse(&.{ "-p", "--session", id, "-c" }).diagnostic;
    try testing.expectEqual(Failure.conflict, pair.failure);
    try testing.expectEqualStrings("--session", pair.arg);
    try testing.expectEqualStrings("-c", pair.value.?);
    try testing.expectEqual(Failure.conflict, parse(&.{ "-p", "--model", "m", "-c" }).diagnostic.failure);
    try testing.expectEqual(Failure.conflict, parse(&.{ "-p", "--reasoning", "r", "--session", id }).diagnostic.failure);
    try testing.expectEqual(Failure.conflict, parse(&.{ "--rpc", "-p" }).diagnostic.failure);
}

test "parse ties the print flags and the prompt to -p" {
    const json = parse(&.{"--json"}).diagnostic;
    try testing.expectEqual(Failure.needs_print, json.failure);
    try testing.expectEqualStrings("--json", json.arg);
    try testing.expectEqual(Scope.root, json.scope);
    try testing.expectEqualStrings("-c", parse(&.{"-c"}).diagnostic.arg);
    try testing.expectEqual(Failure.extra_argument, parse(&.{ "--rpc", "hi" }).diagnostic.failure);
    // A `-p` in the value of an option is a value, not the print flag.
    try testing.expectEqual(Failure.needs_print, parse(&.{ "--model", "-p" }).diagnostic.failure);
    try testing.expectEqualStrings("-p", parse(&.{ "-p", "--model", "-p" }).command.print.model.?);
}
