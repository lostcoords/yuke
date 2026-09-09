//! Drive one device login to its single terminal outcome, then store the grant it produced.

const std = @import("std");
const ai = @import("ai");
const proto = @import("proto");
const provider = @import("../provider.zig");
const http = @import("../../net/http.zig");
const poller = @import("../../net/poller.zig");
const App = @import("../../app/app.zig").App;
const login_runtime = @import("login_runtime.zig");
const CredentialLock = @import("credential_lock.zig");

const oauth = provider.oauth;
const xai = provider.oauth_xai;
const codex = provider.oauth_codex;

/// One login response fits this. The flows read a token document, never a model list.
const response_bytes = http.max_oauth_response_bytes;

/// No flow reports a lifetime, so the engine bounds the login to a fixed maximum.
const max_lifetime_ms: u64 = 15 * 60 * 1000;

/// Ask the provider for a code the human types. The caller answers its client with the result.
pub fn start(arena: std.mem.Allocator, seam: oauth.Http, flow: login_runtime.Flow, body_out: []u8) !oauth.Start {
    return switch (flow) {
        .xai => xai.start(arena, seam, body_out),
        .codex => codex.start(arena, seam, body_out),
    };
}

/// Own the slot until it publishes exactly one `auth.login_finished`.
pub fn run(runtime: *App, slot: *login_runtime.LoginSlot) void {
    var client: http.Client = .init(runtime.gpa, runtime.io);
    defer client.deinit();
    const outcome = drive(runtime, slot, oauth.Http.fromClient(&client)) catch |err| blk: {
        std.log.err("login for {s} failed: {t}", .{ slot.provider_id, err });
        break :blk proto.auth.AuthLoginOutcome{ .failed = .{ .message = "the login could not finish" } };
    };
    finish(runtime, slot, outcome);
}

/// Poll through `seam` until one terminal outcome. A test replays the provider through it.
fn drive(runtime: *App, slot: *login_runtime.LoginSlot, seam: oauth.Http) !proto.auth.AuthLoginOutcome {
    const body = try runtime.gpa.alloc(u8, response_bytes);
    defer runtime.gpa.free(body);

    // The clock counts the request time too, so a slow provider cannot outlast the deadline.
    const began_ms = runtime.nowMillis();
    var pace: poller.Poller = .init(0, slot.start.interval_ms, max_lifetime_ms);
    if (try slot.cancel.holdFor(runtime.io, pace.firstWaitMs())) return .{ .canceled = .{} };

    while (true) {
        var arena: std.heap.ArenaAllocator = .init(runtime.gpa);
        defer arena.deinit();

        // One poll per turn, because an xAI poll that returns tokens spends the device code.
        const elapsed_ms = runtime.nowMillis() -| began_ms;
        if (elapsed_ms >= max_lifetime_ms) return .{ .failed = .{ .message = "the login expired before approval" } };

        const result: ?oauth.Poll = pollFlow(arena.allocator(), slot, seam, runtime.nowMillis(), body) catch |err| switch (err) {
            oauth.Error.PreFlight, oauth.Error.Transient => null,
            else => return .{ .failed = .{ .message = "the provider refused the login" } },
        };

        const reply: poller.Reply = if (result) |poll| switch (poll) {
            .tokens => |tokens| {
                // Claim with no yield between, so a later cancel cannot contradict the outcome.
                if (slot.cancel.requested) return .{ .canceled = .{} };
                try install(runtime, arena.allocator(), slot, tokens);
                return .{ .succeeded = .{} };
            },
            .pending => .{ .pending = null },
            .slow_down => .{ .slow_down = null },
        } else .unavailable;

        switch (pace.step(reply, runtime.nowMillis() -| began_ms)) {
            .failed => |failure| return .{ .failed = .{ .message = switch (failure) {
                .expired => "the login expired before approval",
                .offline => "the provider stayed unreachable",
            } } },
            .wait_ms => |delay_ms| if (try slot.cancel.holdFor(runtime.io, delay_ms)) return .{ .canceled = .{} },
        }
    }
}

fn pollFlow(arena: std.mem.Allocator, slot: *login_runtime.LoginSlot, seam: oauth.Http, now_ms: u64, body: []u8) !oauth.Poll {
    return switch (slot.flow) {
        .xai => xai.poll(arena, seam, slot.start.device_auth_id, now_ms, body),
        .codex => codex.poll(arena, seam, slot.start.device_auth_id, slot.start.user_code, now_ms, body),
    };
}

/// Store the grant through the one mutator, so the write cannot lose another edit.
fn install(runtime: *App, arena: std.mem.Allocator, slot: *login_runtime.LoginSlot, tokens: oauth.Tokens) !void {
    const grant: provider.config.Grant = .{
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .expires_at_ms = tokens.expires_at_ms,
        .account_id = tokens.account_id,
    };
    if (try runtime.store.edit(arena, slot.provider_id, .{ .set_grant = grant })) runtime.announceCatalogChanged();
    runtime.announceAuthChanged(slot.provider_id, .oauth);
}

/// Publish the one terminal outcome and drop the login. Nothing reaches the slot after this.
fn finish(runtime: *App, slot: *login_runtime.LoginSlot, outcome: proto.auth.AuthLoginOutcome) void {
    const note: proto.rpc.Notification = .{ .method = .@"auth.login_finished", .params = .{ .auth_login_finished_data = .{
        .login_id = slot.id,
        .provider_id = slot.provider_id,
        .outcome = outcome,
    } } };
    runtime.engine.sinks.emit(note);
    runtime.logins.remove(slot.id);
}

/// Report when the soonest local grant lapses, so the scheduler wakes before it does.
pub fn soonestExpiry(runtime: *App) ?u64 {
    const loaded = runtime.store.local orelse return null;
    var soonest: ?u64 = null;
    for (loaded.providers) |p| {
        const auth = p.auth orelse continue;
        if (auth != .oauth or auth.oauth.refresh_token == null) continue;
        const at = auth.oauth.expires_at_ms;
        if (soonest == null or at < soonest.?) soonest = at;
    }
    return soonest;
}

/// Rotate the one local grant inside the margin. A terminal failure lapses it instead of retrying.
pub fn refreshOnce(runtime: *App, margin_ms: u64) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(runtime.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A rotating refresh token is spent exactly once. Several yuke processes may share this file,
    // so the lock covers the whole refresh: the read from disk, the expiry check, the network
    // call, and the write. A lock only around the write would still send the same token twice.
    const path = runtime.store.path orelse return false;
    const lock = CredentialLock.acquire(runtime.gpa, runtime.io, path) catch |err| {
        // Keep the cancel, so the scheduler leaves its wait loop.
        if (err == error.Canceled) return error.Canceled;
        std.log.warn("cannot lock the credential file: {t}", .{err});
        return false; // the holder refreshes it; the next pass reads the result
    };
    defer if (lock) |held| held.release(runtime.io);

    // Read the file again under the lock. Another process may have rotated this grant already,
    // and the layer in memory would still name the token it spent.
    // A stale layer could resend a token another process already spent, so a failed read ends the pass.
    _ = runtime.store.reload() catch |err| {
        if (err == error.Canceled) return error.Canceled;
        std.log.warn("cannot reread providers.json: {t}", .{err});
        return false;
    };

    const due = try dueGrant(runtime, arena, margin_ms) orelse return false;
    // A cancel between the send and the write would leave the rotation unknown, so it waits.
    const previous = runtime.io.swapCancelProtection(.blocked);
    defer _ = runtime.io.swapCancelProtection(previous);

    var client: http.Client = .init(runtime.gpa, runtime.io);
    defer client.deinit();
    const seam = oauth.Http.fromClient(&client);

    const body = try arena.alloc(u8, response_bytes);
    // `dueGrant` selects only a grant that can rotate, so this token is present.
    const old = due.grant.refresh_token.?;

    const tokens = refreshFlow(arena, due.flow, seam, old, runtime.nowMillis(), body) catch |err| switch (err) {
        // The request never left or the call spends no token, so the caller may repeat it.
        oauth.Error.PreFlight, oauth.Error.Transient => return err,
        // The rotation may have landed, so repeating it would cost the whole grant.
        else => {
            std.log.warn("refresh for {s} ended the grant: {t}", .{ due.provider_id, err });
            keep(runtime, arena, due, lapsed(due.grant));
            return moreDue(runtime, arena, margin_ms);
        },
    };

    // A response that omits a replacement leaves the old refresh token current.
    keep(runtime, arena, due, .{
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token orelse old,
        .expires_at_ms = tokens.expires_at_ms,
        .account_id = tokens.account_id orelse due.grant.account_id,
    });
    return moreDue(runtime, arena, margin_ms);
}

/// Report whether another grant still waits, so the caller runs again instead of sleeping.
fn moreDue(runtime: *App, arena: std.mem.Allocator, margin_ms: u64) bool {
    const next = dueGrant(runtime, arena, margin_ms) catch return false;
    return next != null;
}

/// Write the rotated grant. A failed write returns no error, because a retry would spend it twice.
/// The layer in memory then forgets the grant, so no later pass reads the token this call replaced.
fn keep(runtime: *App, arena: std.mem.Allocator, due: Due, grant: provider.config.Grant) void {
    store(runtime, arena, due, grant) catch |err| {
        std.log.warn("cannot store the grant for {s}: {t}", .{ due.provider_id, err });
        runtime.store.forgetGrant(due.provider_id);
    };
}

/// Return the grant a terminal rotation leaves, which holds nothing the engine may send again.
fn lapsed(grant: provider.config.Grant) provider.config.Grant {
    var dead = grant;
    dead.expires_at_ms = 0;
    dead.refresh_token = null;
    return dead;
}

/// One grant that needs its replacement, and the flow that can produce one.
const Due = struct {
    provider_id: []const u8,
    flow: login_runtime.Flow,
    grant: provider.config.Grant,
};

fn dueGrant(runtime: *App, arena: std.mem.Allocator, margin_ms: u64) !?Due {
    const loaded = runtime.store.local orelse return null;
    const now_ms = runtime.nowMillis();
    for (loaded.providers) |p| {
        const auth = p.auth orelse continue;
        if (auth != .oauth) continue;
        if (auth.oauth.refresh_token == null) continue;
        if (auth.oauth.expires_at_ms > now_ms +| margin_ms) continue;

        const row = ai.catalog.find(p.id) orelse continue;
        const flow = switch (row.auth) {
            .oauth => |name| login_runtime.Flow.parse(name) orelse continue,
            .api_key => continue,
        };
        // The refresh yields, so a concurrent edit could free the layer these slices point into.
        return .{
            .provider_id = try arena.dupe(u8, p.id),
            .flow = flow,
            .grant = .{
                .access_token = try arena.dupe(u8, auth.oauth.access_token),
                .refresh_token = try arena.dupe(u8, auth.oauth.refresh_token.?),
                .expires_at_ms = auth.oauth.expires_at_ms,
                .account_id = if (auth.oauth.account_id) |id| try arena.dupe(u8, id) else null,
            },
        };
    }
    return null;
}

fn refreshFlow(arena: std.mem.Allocator, flow: login_runtime.Flow, seam: oauth.Http, token: []const u8, now_ms: u64, body: []u8) !oauth.Tokens {
    return switch (flow) {
        .xai => xai.refresh(arena, seam, token, now_ms, body),
        .codex => codex.refresh(arena, seam, token, now_ms, body),
    };
}

/// Lapse the grant, so the run path refuses it and the client asks the human to log in again.
fn store(runtime: *App, arena: std.mem.Allocator, due: Due, grant: provider.config.Grant) !void {
    if (try runtime.store.edit(arena, due.provider_id, .{ .set_grant = grant })) runtime.announceCatalogChanged();
    runtime.announceAuthChanged(due.provider_id, .oauth);
}

const testing = std.testing;

/// One login under test. The engine borrows the runtime fields, so the probe must not move after `init`.
const Probe = struct {
    runtime: App = undefined,
    env: std.process.Environ.Map,
    slot: *login_runtime.LoginSlot = undefined,
    canned: oauth.CannedHttp,
    transport: ai.transport.CannedTransport = .{ .bytes = ai.transport.canned_reply },
    outcome: ?proto.auth.AuthLoginOutcome = null,

    fn init(self: *Probe, io: std.Io, replies: []const oauth.CannedHttp.Reply) !void {
        const database = @import("../../store/store.zig");
        self.* = .{ .env = .init(testing.allocator), .canned = .{ .replies = replies } };
        try self.runtime.initTest(testing.allocator, io, try database.Database.openTest(), &self.env, self.transport.transport());
    }

    /// The engine borrows the store, the logins, and the database, so it closes first.
    fn deinit(self: *Probe) void {
        self.runtime.engine.close();
        self.runtime.db.deinit();
        self.runtime.store.deinit();
        self.runtime.logins.deinit();
        self.env.deinit();
    }

    /// Reserve one slot. The poller floor turns the one-millisecond interval into a one-second wait.
    fn reserve(self: *Probe, provider_id: []const u8, flow: login_runtime.Flow) !void {
        const arena: std.heap.ArenaAllocator = .init(testing.allocator);
        self.slot = try self.runtime.logins.reserve(.bytes(@splat(7)), arena, provider_id, flow);
        self.slot.start = .{ .user_code = "UC", .device_auth_id = "dai", .interval_ms = 1, .verification_url = "" };
    }

    fn driveTask(self: *Probe) !void {
        self.outcome = try drive(&self.runtime, self.slot, self.canned.seam());
    }
};

test "a canceled login stops before its first poll" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{});
    defer probe.deinit();
    try probe.reserve("xai", .xai);
    probe.slot.cancel.requested = true;

    var task = try rt.spawn(Probe.driveTask, .{&probe});
    try task.join();

    try testing.expect(probe.outcome.? == .canceled);
    try testing.expectEqual(@as(usize, 0), probe.canned.index); // The provider saw no request.
}

test "a refused poll fails the login and stores nothing" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{.{ .answer = .{ .status = 400, .body = "{\"error\":\"access_denied\"}" } }});
    defer probe.deinit();
    try probe.reserve("xai", .xai);

    var task = try rt.spawn(Probe.driveTask, .{&probe});
    try task.join();

    try testing.expectEqualStrings("the provider refused the login", probe.outcome.?.failed.message);
    try testing.expectEqual(@as(usize, 1), probe.canned.index); // One poll ran and ended the login.
    try testing.expect(probe.runtime.store.local == null);
}

test "an approved codex login stores the grant" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{
        .{ .answer = .{ .status = 200, .body = "{\"authorization_code\":\"ac\",\"code_verifier\":\"cv\"}" } },
        .{ .answer = .{ .status = 200, .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":60}" } },
    });
    defer probe.deinit();
    // The grant lands in a file, so the store needs a path the writer can create.
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(rt.io(), &dir_buf)];
    probe.runtime.store.path = try std.fs.path.join(testing.allocator, &.{ dir, "providers.json" });
    try probe.reserve("openai-codex", .codex);

    var task = try rt.spawn(Probe.driveTask, .{&probe});
    try task.join();

    try testing.expect(probe.outcome.? == .succeeded);
    try testing.expectEqual(@as(usize, 2), probe.canned.index); // The poll and the exchange both ran.
    const p = probe.runtime.store.local.?.providers[0];
    try testing.expectEqualStrings("openai-codex", p.id);
    try testing.expectEqualStrings("at", p.auth.?.oauth.access_token);
    try testing.expectEqualStrings("rt", p.auth.?.oauth.refresh_token.?);
}

/// Keep the last notification, so a test can read what `finish` published.
const NoteSink = struct {
    method: ?proto.enums.BroadcastName = null,
    count: usize = 0,

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *NoteSink = @ptrCast(@alignCast(ctx));
        self.method = note.method;
        self.count += 1;
    }
};

test "finish publishes one login_finished and drops the slot" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{});
    defer probe.deinit();
    try probe.reserve("xai", .xai);
    var sink: NoteSink = .{};
    probe.runtime.engine.sinks.add(.{ .ctx = &sink, .on_event = NoteSink.onEvent });

    finish(&probe.runtime, probe.slot, .{ .canceled = .{} });

    try testing.expectEqual(proto.enums.BroadcastName.@"auth.login_finished", sink.method.?);
    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expect(probe.runtime.logins.byProvider("xai") == null);
}
