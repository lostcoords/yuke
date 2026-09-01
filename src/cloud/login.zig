//! Run the `yuke login` device-code enrollment, which owns the clock, the terminal, and the files.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const paths = @import("../paths/paths.zig");
const http = @import("../net/http.zig");
const identity = @import("identity.zig");
const poller = @import("../net/poller.zig");
const protocol = @import("protocol.zig");
const endpoint = @import("endpoint.zig");

const Allocator = std.mem.Allocator;

const start_path = "/api/v1/device_codes";
const poll_path = "/api/v1/device_codes/token";

/// The name that the approval screen shows when the host name is unavailable.
const fallback_name = "unknown device";

pub const Error = error{
    /// A script gave no `--role` and no terminal can ask for one.
    RoleRequired,
    /// No data directory exists for the durable files.
    NoDataDir,
    /// The control plane refused or ended the enrollment.
    Rejected,
};

/// Enroll this machine. It writes the durable files only after the control plane approves.
pub fn run(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: cli.Login) !void {
    const dir_path = (try paths.dataDir(gpa, env)) orelse {
        std.log.err("yuke login: no data directory could be resolved", .{});
        return error.NoDataDir;
    };
    defer gpa.free(dir_path);

    var dir = try identity.openDataDir(io, dir_path);
    defer dir.close(io);

    const role = opts.role orelse try promptRole(io);
    var want_device = role != .client;
    var want_session = role != .daemon;

    // Read each principal once. It answers both whether the machine is enrolled and which key to keep.
    const stored_device = identity.read(gpa, io, dir, identity.Device, .device);
    const stored_session = identity.read(gpa, io, dir, identity.Session, .session);

    // A valid principal stays untouched unless the user asks to replace it.
    if (!opts.force) {
        if (want_device and stored_device != null) {
            try print(io, "This machine is already enrolled as a daemon. Use --force to replace it.\n", .{});
            want_device = false;
        }
        if (want_session and stored_session != null) {
            try print(io, "This machine is already enrolled as a client. Use --force to replace it.\n", .{});
            want_session = false;
        }
    }
    if (!want_device and !want_session) return;

    const intent: protocol.Intent = if (want_device and want_session)
        .both
    else if (want_session)
        .client
    else
        .daemon;

    // The server forces a `cli` session on a combined grant, so record the same value.
    const kind: protocol.SessionKind = if (intent == .both) .cli else switch (opts.kind) {
        .cli => .cli,
        .token => .token,
    };

    // The device key pins the Noise handshake, so a replacement keeps the key that peers know.
    var device_secret: ?[identity.secret_length]u8 = null;
    if (want_device) {
        device_secret = if (stored_device) |held| held.secret else null;
        if (device_secret == null) device_secret = try identity.generateSecret(io);
    }

    // A token session presents only a bearer credential, so it needs no key.
    var session_secret: ?[identity.secret_length]u8 = null;
    if (want_session and kind == .cli) {
        session_secret = if (stored_session) |held| held.secret else null;
        if (session_secret == null) session_secret = try identity.generateSecret(io);
    }

    const base = endpoint.baseUrl(env, opts.cloud);

    const start_url = try std.mem.concat(gpa, u8, &.{ base, start_path });
    defer gpa.free(start_url);
    const poll_url = try std.mem.concat(gpa, u8, &.{ base, poll_path });
    defer gpa.free(poll_url);

    var name_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = opts.name orelse hostName(env, &name_buf) orelse fallback_name;

    var client: http.Client = .init(gpa, io, http.default_timeout);
    defer client.deinit();

    const buf = try gpa.alloc(u8, http.max_response_bytes);
    defer gpa.free(buf);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const public_key = if (device_secret) |s| try identity.publicKeyBase64(s) else null;
    const start_body = try protocol.encodeStart(gpa, .{
        .name = name,
        .platform = @tagName(builtin.os.tag),
        .static_public_key = if (public_key) |*k| k else null,
        .intent = intent,
        .session_kind = kind,
    });
    defer gpa.free(start_body);

    const start = try requestStart(&client, arena.allocator(), start_url, start_body, buf);
    try print(io,
        \\
        \\To authorize this machine, open:
        \\
        \\  {s}
        \\
        \\and confirm the code {s}.
        \\
        \\Waiting for approval...
        \\
    , .{ start.verification_uri_complete, start.user_code });

    const poll_body = try protocol.encodePoll(gpa, start.device_code);
    defer gpa.free(poll_body);

    const credential = try awaitApproval(io, &client, &arena, poll_url, poll_body, buf, start, intent);

    // The control plane approved, so the durable files may now change.
    if (want_device) {
        const stored = identity.encodeSecret(device_secret.?);
        try identity.writeMeta(io, dir, .device, identity.Device{
            .device_id = credential.device_id,
            .credential = credential.credential,
            .relay_url = credential.relay_url,
            .identity_key = &stored,
            .schema_version = identity.schema_version,
        });
        try print(io, "Enrolled daemon {s} (relay {s}).\n", .{ credential.device_id, credential.relay_url });
    }
    if (want_session) {
        const stored: ?[identity.key_b64_length]u8 = if (session_secret) |secret| identity.encodeSecret(secret) else null;
        try identity.writeMeta(io, dir, .session, identity.Session{
            .session_id = credential.session_id,
            .credential = credential.sessionCredential(),
            .relay_url = credential.relay_url,
            .local_device_id = credential.device_id,
            .kind = @tagName(kind),
            .identity_key = if (stored) |*key| key else "",
            .schema_version = identity.schema_version,
        });
        try print(io, "Enrolled client {s}.\n", .{credential.session_id});
    }
}

/// Start one grant. A rejected start is terminal, because no grant exists yet to poll.
fn requestStart(
    client: *http.Client,
    arena: Allocator,
    url: []const u8,
    body: []const u8,
    buf: []u8,
) !protocol.Start {
    const response = client.postJson(url, body, buf) catch |err| {
        reportRequestError(url, err);
        return error.Rejected;
    };

    if (response.status < 200 or response.status >= 300) {
        const problem = protocol.decodeProblem(arena, response.body);
        std.log.err("yuke login: the control plane refused the enrollment: {s}", .{describe(problem)});
        return error.Rejected;
    }

    return protocol.decodeStart(arena, response.body) catch {
        std.log.err("yuke login: the control plane returned an unexpected response", .{});
        return error.Rejected;
    };
}

/// Poll until the grant is terminal. `arena` resets each poll, and the result borrows the last one.
fn awaitApproval(
    io: std.Io,
    client: *http.Client,
    arena: *std.heap.ArenaAllocator,
    url: []const u8,
    body: []const u8,
    buf: []u8,
    start: protocol.Start,
    intent: protocol.Intent,
) !protocol.Credential {
    const base = std.Io.Timestamp.now(io, .boot);
    var state: poller.Poller = .init(0, start.interval_s *| 1_000, start.expires_in_s *| 1_000);
    // RFC 8628 section 3.5 requires one interval before the first request.
    try std.Io.sleep(io, .fromMilliseconds(@intCast(state.firstWaitMs())), .boot);

    while (true) {
        _ = arena.reset(.retain_capacity);
        const scratch = arena.allocator();

        var problem: protocol.Problem = .{};
        const reply: poller.Reply = if (client.postJson(url, body, buf)) |response| blk: {
            if (response.status < 200 or response.status >= 300) {
                problem = protocol.decodeProblem(scratch, response.body);
            }
            const reply = protocol.classify(response.status, problem);
            // An approved poll is the only body that carries the credential.
            if (reply == .approved) return protocol.decodeCredential(scratch, response.body, intent) catch {
                std.log.err("yuke login: the control plane returned an unexpected credential", .{});
                return error.Rejected;
            };
            break :blk reply;
        } else |err| switch (err) {
            // A bad URL never becomes valid, so it must not retry until the deadline.
            error.BadUrl => {
                reportRequestError(url, err);
                return error.Rejected;
            },
            else => .unavailable,
        };

        switch (state.step(reply, elapsedMs(io, base))) {
            .done => unreachable, // An approved reply returns above.
            .failed => |failure| {
                std.log.err("yuke login: {s}", .{explain(failure, problem)});
                return error.Rejected;
            },
            .wait_ms => |delay_ms| try std.Io.sleep(io, .fromMilliseconds(@intCast(delay_ms)), .boot),
        }
    }
}

/// Return the milliseconds since `base`, from the boot clock, because the server times the grant.
fn elapsedMs(io: std.Io, base: std.Io.Timestamp) u64 {
    const elapsed = base.durationTo(std.Io.Timestamp.now(io, .boot));
    return @intCast(@max(elapsed.toMilliseconds(), 0));
}

/// Report one failed request. A malformed URL is a user mistake, not an unreachable server.
fn reportRequestError(url: []const u8, err: anyerror) void {
    if (err == error.BadUrl) {
        std.log.err("yuke login: '{s}' is not a valid control-plane URL", .{url});
    } else {
        std.log.err("yuke login: could not reach the control plane at {s} ({t})", .{ url, err });
    }
}

/// Explain one terminal failure to the user. The server detail wins when it exists.
fn explain(failure: poller.Failure, problem: protocol.Problem) []const u8 {
    return switch (failure) {
        .expired => "the enrollment expired before approval; run `yuke login` again",
        .offline => "the control plane stayed unreachable; check the network and run `yuke login` again",
        .terminal => describe(problem),
    };
}

fn describe(problem: protocol.Problem) []const u8 {
    if (problem.detail.len != 0) return problem.detail;
    return switch (problem.code) {
        .access_denied => "the request was denied",
        .plan_limit => "this account has no free device slot",
        .email_unverified => "verify the account email address first",
        .invalid_grant, .expired_token => "the enrollment expired; run `yuke login` again",
        else => "the control plane refused the enrollment",
    };
}

/// Return the kernel host name. It names the machine on the approval screen.
fn hostName(env: *const std.process.Environ.Map, buf: *[std.posix.HOST_NAME_MAX]u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const value = env.get("COMPUTERNAME") orelse return null;
        return if (value.len == 0) null else value;
    }
    return std.posix.gethostname(buf) catch null;
}

/// Ask which principals to enroll. A script has no terminal, so it must pass `--role`.
fn promptRole(io: std.Io) !cli.Role {
    const stdin = std.Io.File.stdin();
    if (!(try stdin.isTty(io))) {
        std.log.err("yuke login: a script must pass --role daemon, client, or both", .{});
        return error.RoleRequired;
    }

    try print(io,
        \\Enroll this machine as:
        \\
        \\  [1] daemon + client   park a daemon here and use the TUI
        \\  [2] daemon only       a headless host that parks an agent
        \\  [3] client only       no local daemon, or a token for CI
        \\
        \\Choice [1]: 
    , .{});

    var buf: [64]u8 = undefined;
    var reader = stdin.readerStreaming(io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch "";
    const choice = std.mem.trim(u8, line, " \t\r");

    if (choice.len == 0 or std.mem.eql(u8, choice, "1")) return .both;
    if (std.mem.eql(u8, choice, "2")) return .daemon;
    if (std.mem.eql(u8, choice, "3")) return .client;

    std.log.err("yuke login: unknown choice '{s}'", .{choice});
    return error.RoleRequired;
}

/// Write one line to standard output. Login stays line oriented, so it works over a pipe.
fn print(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.print(format, args);
    try out.interface.flush();
}

const testing = std.testing;

test "describe prefers the server detail" {
    try testing.expectEqualStrings("no slots left", describe(.{ .code = .plan_limit, .detail = "no slots left" }));
    try testing.expectEqualStrings("this account has no free device slot", describe(.{ .code = .plan_limit }));
    try testing.expectEqualStrings("the request was denied", describe(.{ .code = .access_denied }));
    try testing.expectEqualStrings("the control plane refused the enrollment", describe(.{}));
}

test "explain reports the local failures without a server detail" {
    try testing.expectEqualStrings(
        "the enrollment expired before approval; run `yuke login` again",
        explain(.expired, .{}),
    );
    try testing.expectEqualStrings(
        "the control plane stayed unreachable; check the network and run `yuke login` again",
        explain(.offline, .{}),
    );
    try testing.expectEqualStrings("denied by the human", explain(.terminal, .{
        .code = .access_denied,
        .detail = "denied by the human",
    }));
}
