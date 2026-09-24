//! Drive one device login to its single terminal outcome, then store the grant it produced.

const std = @import("std");
const execution = @import("../../execution.zig");
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
                if (slot.cancel.isRequested()) return .{ .canceled = .{} };
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
    if (try runtime.store.edit(arena, slot.provider_id, .{ .set_grant = tokens })) runtime.announceCatalogChanged();
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

    // A rotating refresh token is spent exactly once and several yuke processes may share this file, so the lock covers the whole refresh (disk read, expiry check, network call, write); a lock only around the write would still send the same token twice.
    const lock_path = runtime.store.lock_path orelse return false;
    const lock = CredentialLock.acquire(runtime.io, lock_path) catch |err| {
        // Keep the cancel, so the scheduler leaves its wait loop.
        if (err == error.Canceled) return error.Canceled;
        std.log.warn("cannot lock the credential file: {t}", .{err});
        return false; // the holder refreshes it; the next pass reads the result
    };
    defer if (lock) |held| held.release(runtime.io);

    // Read the file again under the lock because another process may have rotated this grant while memory still names the spent token; a stale layer could resend it, so a failed read ends the pass.
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

    const tokens = (switch (due.flow) {
        .xai => xai.refresh(arena, seam, old, runtime.nowMillis(), body),
        .codex => codex.refresh(arena, seam, old, runtime.nowMillis(), body),
    }) catch |err| switch (err) {
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

/// Write the rotated grant; a failed write returns no error because a retry would spend it twice, and the memory layer then forgets the grant so no later pass reads the replaced token.
fn keep(runtime: *App, arena: std.mem.Allocator, due: Due, grant: provider.config.Grant) void {
    const changed = runtime.store.edit(arena, due.provider_id, .{ .set_grant = grant }) catch |err| {
        std.log.warn("cannot store the grant for {s}: {t}", .{ due.provider_id, err });
        runtime.store.forgetGrant(due.provider_id);
        return;
    };
    if (changed) runtime.announceCatalogChanged();
}

/// Lapse the grant, so the run path refuses it and the client asks the human to log in again.
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

const app_fixture = @import("../../app/fixture.zig");
const zio = @import("zio");
const testing = std.testing;

/// One login under test. The engine borrows the runtime fields, so the probe must not move after `init`.
const Probe = struct {
    runtime: App = undefined,
    env: std.process.Environ.Map,
    blobs: testing.TmpDir = undefined,
    blob_dir: [std.Io.Dir.max_path_bytes]u8 = undefined,
    slot: *login_runtime.LoginSlot = undefined,
    canned: oauth.CannedHttp,
    transport: ai.testing.CannedTransport = .{ .bytes = ai.testing.canned_reply },
    outcome: ?proto.auth.AuthLoginOutcome = null,
    elapsed_ms: u64 = 0,
    waits: [8]u64 = undefined,
    wait_count: usize = 0,
    cancel_at_wait: ?usize = null,

    const epoch_ms = 1_700_000_000_000;
    const time_vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.now = now;
        table.futexWait = wait;
        table.futexWake = wake;
        break :blk table;
    };

    fn timeIo(self: *Probe) std.Io {
        return .{ .userdata = self, .vtable = &time_vtable };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const self: *Probe = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(clock == .real or clock == .awake);
        return .{ .nanoseconds = @as(i96, epoch_ms + self.elapsed_ms) * std.time.ns_per_ms };
    }

    fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *Probe = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(ptr == @as(*const u32, @ptrCast(&self.slot.cancel.event)));
        std.debug.assert(expected == @intFromEnum(std.Io.Event.waiting));
        std.debug.assert(self.wait_count < self.waits.len);
        const left = timeout.toDurationFromNow(self.timeIo()).?;
        std.debug.assert(left.clock == .awake);
        const delay_ms: u64 = @intCast(left.raw.toMilliseconds());
        std.debug.assert(delay_ms > 0);
        self.waits[self.wait_count] = delay_ms;
        self.wait_count += 1;
        if (self.cancel_at_wait == self.wait_count) {
            self.slot.cancel.request(self.timeIo());
        } else {
            self.elapsed_ms += delay_ms;
        }
    }

    fn wake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        const self: *Probe = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(ptr == @as(*const u32, @ptrCast(&self.slot.cancel.event)));
        std.debug.assert(max_waiters > 0);
        std.debug.assert(self.slot.cancel.isRequested());
    }

    fn init(self: *Probe, io: std.Io, replies: []const oauth.CannedHttp.Reply) !void {
        self.* = .{ .env = .init(testing.allocator), .canned = .{ .replies = replies } };
        self.blobs = testing.tmpDir(.{});
        try app_fixture.init(&self.runtime, testing.allocator, io, self.blob_dir[0..try self.blobs.dir.realPath(testing.io, &self.blob_dir)], self.transport.transport(), execution.testContext(&self.env));
    }

    fn deinit(self: *Probe) void {
        self.runtime.deinit();
        self.env.deinit();
        self.blobs.cleanup();
    }

    /// The poller must raise this interval to one second.
    fn reserve(self: *Probe, provider_id: []const u8, flow: login_runtime.Flow) !void {
        const arena: std.heap.ArenaAllocator = .init(testing.allocator);
        self.slot = try self.runtime.logins.reserve(.bytes(@splat(7)), arena, provider_id, flow);
        self.slot.start = .{ .user_code = "UC", .device_auth_id = "dai", .interval_ms = 1, .verification_url = "" };
    }

    fn driveTask(self: *Probe) !void {
        // Only the driver borrows virtual time; the store and engine retain the reactor I/O.
        const io = self.runtime.io;
        self.runtime.io = self.timeIo();
        defer self.runtime.io = io;
        self.outcome = try drive(&self.runtime, self.slot, self.canned.seam());
    }
};

test "a canceled login stops before its first poll" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{});
    defer probe.deinit();
    try probe.reserve("xai", .xai);
    probe.slot.cancel.requested.store(true, .release);

    var task = try rt.io().concurrent(Probe.driveTask, .{&probe});
    try task.await(rt.io());

    try testing.expect(probe.outcome.? == .canceled);
    try testing.expectEqual(@as(usize, 0), probe.wait_count);
    try testing.expectEqual(@as(usize, 0), probe.canned.index); // The provider saw no request.
}

test "a refused poll fails the login and stores nothing" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();

    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{.{ .answer = .{ .status = 400, .body = "{\"error\":\"access_denied\"}" } }});
    defer probe.deinit();
    try probe.reserve("xai", .xai);

    var task = try rt.io().concurrent(Probe.driveTask, .{&probe});
    try task.await(rt.io());

    try testing.expectEqualStrings("the provider refused the login", probe.outcome.?.failed.message);
    try testing.expectEqualSlices(u64, &.{1000}, probe.waits[0..probe.wait_count]);
    try testing.expectEqual(@as(usize, 1), probe.canned.index); // One poll ran and ended the login.
    try testing.expect(probe.runtime.store.local == null);
}

test "an approved codex login stores the grant" {
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
    probe.runtime.store.path = try std.Io.Dir.path.join(testing.allocator, &.{ dir, "providers.json" });
    try probe.reserve("openai-codex", .codex);

    var task = try rt.io().concurrent(Probe.driveTask, .{&probe});
    try task.await(rt.io());

    try testing.expect(probe.outcome.? == .succeeded);
    try testing.expectEqualSlices(u64, &.{1000}, probe.waits[0..probe.wait_count]);
    try testing.expectEqual(@as(usize, 2), probe.canned.index); // The poll and the exchange both ran.
    const p = probe.runtime.store.local.?.providers[0];
    try testing.expectEqualStrings("openai-codex", p.id);
    try testing.expectEqualStrings("at", p.auth.?.oauth.access_token);
    try testing.expectEqualStrings("rt", p.auth.?.oauth.refresh_token.?);
    try testing.expectEqual(@as(u64, Probe.epoch_ms + 1000 + 60_000), p.auth.?.oauth.expires_at_ms);
}

test "a cancel during a login wait prevents the next poll" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    for ([_]usize{ 1, 2 }) |cancel_at_wait| {
        var probe: Probe = undefined;
        try probe.init(rt.io(), &.{.{ .answer = .{ .status = 400, .body = "{\"error\":\"authorization_pending\"}" } }});
        defer probe.deinit();
        try probe.reserve("xai", .xai);
        probe.cancel_at_wait = cancel_at_wait;
        var task = try rt.io().concurrent(Probe.driveTask, .{&probe});
        try task.await(rt.io());
        try testing.expect(probe.outcome.? == .canceled);
        try testing.expectEqual(cancel_at_wait, probe.wait_count);
        try testing.expectEqual(cancel_at_wait - 1, probe.canned.index);
        try testing.expectEqual(@as(u64, (cancel_at_wait - 1) * 1000), probe.elapsed_ms);
        try testing.expect(probe.runtime.store.local == null);
    }
}

test "a pending login waits another whole interval before its next poll" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{
        .{ .answer = .{ .status = 400, .body = "{\"error\":\"authorization_pending\"}" } },
        .{ .answer = .{ .status = 400, .body = "{\"error\":\"access_denied\"}" } },
    });
    defer probe.deinit();
    try probe.reserve("xai", .xai);
    var task = try rt.io().concurrent(Probe.driveTask, .{&probe});
    try task.await(rt.io());
    try testing.expectEqualStrings("the provider refused the login", probe.outcome.?.failed.message);
    try testing.expectEqualSlices(u64, &.{ 1000, 1000 }, probe.waits[0..probe.wait_count]);
    try testing.expectEqual(@as(u64, 2000), probe.elapsed_ms);
    try testing.expectEqual(@as(usize, 2), probe.canned.index);
    try testing.expect(probe.runtime.store.local == null);
}

test "a login that reaches its lifetime limit does not poll" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var probe: Probe = undefined;
    try probe.init(rt.io(), &.{});
    defer probe.deinit();
    try probe.reserve("xai", .xai);
    probe.slot.start.interval_ms = max_lifetime_ms;
    var task = try rt.io().concurrent(Probe.driveTask, .{&probe});
    try task.await(rt.io());
    try testing.expectEqualStrings("the login expired before approval", probe.outcome.?.failed.message);
    try testing.expectEqualSlices(u64, &.{max_lifetime_ms}, probe.waits[0..probe.wait_count]);
    try testing.expectEqual(@as(usize, 0), probe.canned.index);
    try testing.expect(probe.runtime.store.local == null);
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
