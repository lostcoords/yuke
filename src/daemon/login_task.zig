//! Drive one device login to its single terminal outcome, then store the grant it produced.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");
const http = @import("../net/http.zig");
const poller = @import("../net/poller.zig");
const State = @import("State.zig");
const login_runtime = @import("login_runtime.zig");

const oauth = provider.oauth;
const xai = provider.oauth_xai;
const codex = provider.oauth_codex;

/// One login response fits this. The flows read a token document, never a model list.
const response_bytes = http.max_oauth_response_bytes;

/// No flow reports a lifetime, so the daemon bounds the login as the reference does.
const max_lifetime_ms: u64 = 15 * 60 * 1000;

/// Ask the provider for a code the human types. The caller answers its client with the result.
pub fn start(arena: std.mem.Allocator, client: *http.Client, flow: login_runtime.Flow, body_out: []u8) !oauth.Start {
    var seam: oauth.ClientHttp = .{ .client = client };
    return switch (flow) {
        .xai => xai.start(arena, seam.seam(), body_out),
        .codex => codex.start(arena, seam.seam(), body_out),
    };
}

/// Own the slot until it publishes exactly one `auth.login_finished`.
pub fn run(state: *State, slot: *login_runtime.LoginSlot) void {
    const outcome = drive(state, slot) catch |err| blk: {
        std.log.err("login for {s} failed: {t}", .{ slot.provider_id, err });
        break :blk wire.auth.AuthLoginOutcome{ .failed = .{ .message = "the login could not finish" } };
    };
    finish(state, slot, outcome);
}

fn drive(state: *State, slot: *login_runtime.LoginSlot) !wire.auth.AuthLoginOutcome {
    var client: http.Client = .init(state.gpa, state.io, .none);
    defer client.deinit();
    var seam: oauth.ClientHttp = .{ .client = &client };

    const body = try state.gpa.alloc(u8, response_bytes);
    defer state.gpa.free(body);

    var pace: poller.Poller = .init(0, slot.start.interval_ms, max_lifetime_ms);
    var waited_ms: u64 = pace.firstWaitMs();
    // RFC 8628 section 3.5 requires one whole interval before the first request.
    if (try sleepOrCancel(state, slot, waited_ms)) return .{ .canceled = .{} };

    while (true) {
        var arena: std.heap.ArenaAllocator = .init(state.gpa);
        defer arena.deinit();

        // One poll per turn, because an xAI poll that returns tokens spends the device code.
        const result: ?oauth.Poll = pollFlow(arena.allocator(), slot, seam.seam(), state.nowMillis(), body) catch |err| switch (err) {
            oauth.Error.PreFlight, oauth.Error.Transient => null,
            else => return .{ .failed = .{ .message = "the provider refused the login" } },
        };

        const reply: poller.Reply = if (result) |poll| switch (poll) {
            .tokens => |tokens| {
                // A cancel that lands during the poll must not install the grant.
                if (slot.cancel_requested) return .{ .canceled = .{} };
                try install(state, arena.allocator(), slot, tokens);
                return .{ .succeeded = .{} };
            },
            .pending => .{ .pending = null },
            .slow_down => .{ .slow_down = null },
        } else .unavailable;

        switch (pace.step(reply, waited_ms)) {
            .done => unreachable, // A token reply returns above.
            .failed => |failure| return .{ .failed = .{ .message = switch (failure) {
                .expired => "the login expired before approval",
                .offline => "the provider stayed unreachable",
                .terminal => "the provider ended the login",
            } } },
            .wait_ms => |delay_ms| {
                waited_ms +|= delay_ms;
                if (try sleepOrCancel(state, slot, delay_ms)) return .{ .canceled = .{} };
            },
        }
    }
}

/// Sleep, or stop early when a cancel wakes the slot. It reports whether the login was canceled.
fn sleepOrCancel(state: *State, slot: *login_runtime.LoginSlot, delay_ms: u64) !bool {
    if (slot.cancel_requested) return true;
    slot.wake_event.waitTimeout(state.io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@intCast(delay_ms)) } }) catch |err| switch (err) {
        error.Timeout => return slot.cancel_requested,
        else => return err,
    };
    return true; // Only a cancel sets the event.
}

fn pollFlow(arena: std.mem.Allocator, slot: *login_runtime.LoginSlot, seam: oauth.Http, now_ms: u64, body: []u8) !oauth.Poll {
    return switch (slot.flow) {
        .xai => xai.poll(arena, seam, slot.start.device_auth_id, now_ms, body),
        .codex => codex.poll(arena, seam, slot.start.device_auth_id, slot.start.user_code, now_ms, body),
    };
}

/// Store the grant through the one mutator, so the write cannot lose another edit.
fn install(state: *State, arena: std.mem.Allocator, slot: *login_runtime.LoginSlot, tokens: oauth.Tokens) !void {
    const grant: provider.config.Grant = .{
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .expires_at_ms = tokens.expires_at_ms,
        .account_id = tokens.account_id,
    };
    if (try state.store.edit(arena, slot.provider_id, .{ .set_grant = grant }, &state.db)) state.announceCatalogChanged();
    state.announceAuthChanged(slot.provider_id, .oauth);
}

/// Publish the one terminal outcome and drop the login. Nothing reaches the slot after this.
fn finish(state: *State, slot: *login_runtime.LoginSlot, outcome: wire.auth.AuthLoginOutcome) void {
    const note: wire.rpc.Notification = .{ .method = .@"auth.login_finished", .params = .{ .auth_login_finished_data = .{
        .login_id = slot.id,
        .provider_id = slot.provider_id,
        .outcome = outcome,
    } } };
    state.publishAll(note, "auth.login_finished");
    state.logins.remove(slot.id);
}
