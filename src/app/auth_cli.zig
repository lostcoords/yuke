//! `yuke login` and `yuke logout`: the auth commands on a terminal, with no JavaScript host.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const proto = @import("proto");
const App = @import("app.zig").App;
const commands = @import("commands.zig");

/// A key line longer than this is not a key.
const max_key_bytes: usize = 4096;

/// Sign in to `provider`, or list every provider with its state when the name is absent. Return the exit status.
pub fn login(gpa: std.mem.Allocator, io: std.Io, runtime: *App, provider: ?[]const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    const id = provider orelse return listProviders(runtime, arena, w);
    const list = try commands.authList(runtime, arena, .{});
    const row = find(list.providers, id) orelse {
        try w.print("yuke login: unknown provider '{s}'\n", .{id});
        return 1;
    };
    return if (row.can_login) deviceLogin(runtime, arena, w, id) else keyLogin(io, runtime, arena, w, id);
}

/// Drop the credential of `provider`. Return the exit status.
pub fn logout(gpa: std.mem.Allocator, io: std.Io, runtime: *App, provider: []const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    _ = commands.authRemove(runtime, arena, .{ .provider_id = provider }) catch |err| switch (err) {
        error.UnknownProvider => {
            try w.print("yuke logout: no credential for '{s}'\n", .{provider});
            return 1;
        },
        error.BadProviderId => {
            try w.print("yuke logout: bad provider name '{s}'\n", .{provider});
            return 1;
        },
        else => return err,
    };
    try w.print("logged out · {s}\n", .{provider});
    return 0;
}

fn find(rows: []const proto.auth.AuthProvider, id: []const u8) ?proto.auth.AuthProvider {
    for (rows) |row| if (std.mem.eql(u8, row.provider_id, id)) return row;
    return null;
}

/// Print one line for each provider: the name, how it signs in, and whether it can serve a turn.
fn listProviders(runtime: *App, arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    const list = try commands.authList(runtime, arena, .{});
    const catalog = try commands.catalogList(runtime, arena, .{});
    const infos = switch (catalog) {
        .full => |full| full.providers,
        .unchanged => unreachable, // no revision was sent, so the engine answers in full
    };
    for (list.providers) |p| {
        const state = stateOf(infos, p.provider_id);
        try w.print("{s:<16} {s:<8} {s}\n", .{ p.provider_id, if (p.can_login) "account" else "api key", stateLabel(state, p) });
    }
    return 0;
}

fn stateOf(infos: []const proto.catalog.ProviderInfo, id: []const u8) ?proto.enums.ProviderState {
    for (infos) |info| if (std.mem.eql(u8, info.id, id)) return info.state;
    return null;
}

/// The words for a provider state. A key provider needs a key where a grant provider needs a login.
fn stateLabel(state: ?proto.enums.ProviderState, p: proto.auth.AuthProvider) []const u8 {
    return switch (state orelse return "") {
        .ready => "ready",
        .needs_credential => if (p.can_login) "needs login" else "needs key",
        .needs_route => "needs route",
        .expired => "expired",
    };
}

/// One login's terminal outcome, copied out of the event because the note borrows the engine's arena.
const Waiter = struct {
    login_id: proto.ids.LoginId,
    done: zio.ResetEvent = .init,
    outcome: enum { succeeded, canceled, failed } = .canceled,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *Waiter = @ptrCast(@alignCast(ctx));
        const data = switch (note.params) {
            .auth_login_finished_data => |d| d,
            else => return,
        };
        if (!std.mem.eql(u8, &data.login_id.raw, &self.login_id.raw)) return;
        std.debug.assert(!self.done.isSet()); // one login publishes one outcome
        switch (data.outcome) {
            .succeeded => self.outcome = .succeeded,
            .canceled => self.outcome = .canceled,
            .failed => |f| {
                self.outcome = .failed;
                self.message_len = @min(f.message.len, self.message.len);
                @memcpy(self.message[0..self.message_len], f.message[0..self.message_len]);
            },
        }
        self.done.set();
    }
};

/// Start the device flow, print the URL and the code, then wait for the one outcome the engine publishes.
fn deviceLogin(runtime: *App, arena: std.mem.Allocator, w: *std.Io.Writer, id: []const u8) !u8 {
    const start = commands.authLogin(runtime, arena, .{ .provider_id = id }) catch |err| {
        try w.print("yuke login: {s}\n", .{loginError(err)});
        return 1;
    };
    try w.print("open  {s}\ncode  {s}\nwaiting for the provider...\n", .{ start.verification_url, start.user_code });
    try w.flush();

    var waiter: Waiter = .{ .login_id = start.login_id };
    runtime.engine.sinks.add(.{ .ctx = @ptrCast(&waiter), .on_event = Waiter.onEvent });
    defer runtime.engine.sinks.remove(@ptrCast(&waiter));
    try waiter.done.wait();

    switch (waiter.outcome) {
        .succeeded => {
            try w.print("logged in · {s}\n", .{id});
            return 0;
        },
        .canceled => {
            try w.print("yuke login: the login was canceled\n", .{});
            return 1;
        },
        .failed => {
            try w.print("yuke login: {s}\n", .{waiter.message[0..waiter.message_len]});
            return 1;
        },
    }
}

fn loginError(err: anyerror) []const u8 {
    return switch (err) {
        error.LoginInProgress => "a login for this provider is already running",
        error.NoLoginFlow, error.UnknownProvider => "this provider has no login",
        error.Unavailable => "the engine is shutting down",
        else => "the provider did not answer the login request",
    };
}

/// Read the key from the terminal with echo off, or from a pipe as it comes, then store it.
fn keyLogin(io: std.Io, runtime: *App, arena: std.mem.Allocator, w: *std.Io.Writer, id: []const u8) !u8 {
    const stdin = std.Io.File.stdin();
    const tty = stdin.isTty(io) catch false;
    if (tty) {
        try w.print("api key for {s}: ", .{id});
        try w.flush();
    }
    const key = try readSecret(io, arena, stdin, tty);
    if (tty) try w.writeByte('\n');
    if (key.len == 0) {
        try w.print("yuke login: no key was given\n", .{});
        return 1;
    }
    _ = commands.authSetApiKey(runtime, arena, .{ .provider_id = id, .api_key = key }) catch |err| {
        try w.print("yuke login: the key was not stored: {t}\n", .{err});
        return 1;
    };
    try w.print("key saved · {s}\n", .{id});
    return 0;
}

/// Read one line. On a terminal the echo stays off while the key comes in, and the old mode returns after.
fn readSecret(io: std.Io, arena: std.mem.Allocator, stdin: std.Io.File, tty: bool) ![]u8 {
    const quiet = tty and builtin.os.tag != .windows;
    const saved: ?std.posix.termios = if (quiet) try std.posix.tcgetattr(stdin.handle) else null;
    if (saved) |mode| {
        var silent = mode;
        silent.lflag.ECHO = false;
        silent.lflag.ECHONL = false;
        try std.posix.tcsetattr(stdin.handle, .NOW, silent);
    }
    defer if (saved) |mode| std.posix.tcsetattr(stdin.handle, .NOW, mode) catch {};

    var buf: [max_key_bytes]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.KeyTooLong,
        error.ReadFailed => return error.ReadFailed,
    };
    return arena.dupe(u8, std.mem.trim(u8, line orelse "", " \t\r\n"));
}

const testing = std.testing;

test "the waiter takes only its own login and keeps the failure text" {
    const mine = proto.ids.LoginId.bytes([_]u8{1} ** 32);
    const other = proto.ids.LoginId.bytes([_]u8{2} ** 32);
    var waiter: Waiter = .{ .login_id = mine };

    Waiter.onEvent(@ptrCast(&waiter), .{ .method = .@"auth.login_finished", .params = .{ .auth_login_finished_data = .{
        .login_id = other,
        .provider_id = "codex",
        .outcome = .{ .succeeded = .{} },
    } } });
    try testing.expect(!waiter.done.isSet());

    Waiter.onEvent(@ptrCast(&waiter), .{ .method = .@"auth.login_finished", .params = .{ .auth_login_finished_data = .{
        .login_id = mine,
        .provider_id = "codex",
        .outcome = .{ .failed = .{ .message = "denied" } },
    } } });
    try testing.expect(waiter.done.isSet());
    try testing.expect(waiter.outcome == .failed);
    try testing.expectEqualStrings("denied", waiter.message[0..waiter.message_len]);
}

test "the state label names what a provider needs" {
    const grant: proto.auth.AuthProvider = .{ .provider_id = "codex", .can_login = true };
    const key: proto.auth.AuthProvider = .{ .provider_id = "minimax", .can_login = false };
    try testing.expectEqualStrings("needs login", stateLabel(.needs_credential, grant));
    try testing.expectEqualStrings("needs key", stateLabel(.needs_credential, key));
    try testing.expectEqualStrings("ready", stateLabel(.ready, key));
    try testing.expectEqualStrings("", stateLabel(null, key));
}
