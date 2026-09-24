//! Loopback HTTP tests cover request validation, bounded responses, and operation ownership.

const std = @import("std");
const zio = @import("zio");
const support = @import("support.zig");
const Host = @import("../host.zig").Host;
const Work = @import("../../session/work.zig");
const bench = @import("../bench/bench.zig");
const Peer = @import("../http_peer.zig").Peer;
const Mode = @import("../http_peer.zig").Mode;

const Cleanup = enum { none, plugin, host, tool, body };
const PoolCase = enum { reuse, recover, stale, no_replay, concurrent, origins };

fn run(mode: Mode, options: struct { cleanup: Cleanup = .none, pool: ?PoolCase = null }) !void {
    const cleanup = options.cleanup;
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const peer = try Peer.create(std.testing.allocator, runtime.io(), mode);
    defer peer.destroy();
    peer.once = options.pool == .recover or options.pool == .stale or options.pool == .no_replay;
    peer.failure_at = if (options.pool == .recover) 1 else 0;
    const second = if (options.pool == .origins) try Peer.create(std.testing.allocator, runtime.io(), .reply) else null;
    defer if (second) |other| other.destroy();
    const host = support.createHostWith(runtime.io(), "");
    defer support.destroyHost(host);
    peer.wake = &host.wake;
    const global = host.ctx.getGlobalObject();
    defer host.ctx.freeValue(global);
    try host.ctx.setPropertyStr(global, "httpUrl", host.ctx.newString(peer.url));
    try host.ctx.setPropertyStr(global, "httpMode", host.ctx.newString(@tagName(mode)));
    try host.ctx.setPropertyStr(global, "httpCleanup", host.ctx.newString(@tagName(cleanup)));
    try host.ctx.setPropertyStr(global, "httpError", host.ctx.newString(""));
    if (options.pool) |scenario| try host.ctx.setPropertyStr(global, "httpPoolCase", host.ctx.newString(@tagName(scenario)));
    if (second) |other| try host.ctx.setPropertyStr(global, "httpSecondUrl", host.ctx.newString(other.url));
    if (cleanup == .none) try support.eval(host, "native_tools/http.test.js") else try support.eval(host, "native_tools/http-lifecycle.test.js");
    var work: Work = .{};
    const call = if (cleanup == .tool) host.calls.submit("fetch_probe", "{}", "/") else null;
    defer if (call) |held| held.finish();
    if (call) |held| held.work = &work;
    if (options.pool == .concurrent) {
        try support.pumpUntil(host, peer, struct {
            fn all(p: *Peer) bool {
                return p.requests.load(.acquire) == 10;
            }
        }.all);
        peer.release.set(host.io);
    }
    if (cleanup != .none) try support.pumpUntilSet(host, &peer.ready);
    if (cleanup != .none and mode == .slow_body) try support.pumpUntilTrue(host, "globalThis.httpReadStarted === true");
    if (cleanup == .body) {
        try std.testing.expectEqual(@as(usize, 1), host.bodies.live.items.len);
        const body = host.bodies.live.items[0];
        body.close();
        try std.testing.expect(!body.done());
        host.bodies.reap(host.gpa);
        try std.testing.expectEqual(@as(usize, 1), host.bodies.live.items.len);
    }
    if (cleanup == .plugin) try host.eval("resumeHttp();", "http-resume.js");
    if (cleanup == .tool) {
        var drain = try host.io.concurrent(Work.drain, .{ &work, host.io });
        drain.await(host.io);
        try std.testing.expectEqual(@as(usize, 0), work.pending);
    }
    if (cleanup == .host) {
        try host.close();
        const done = host.ctx.getPropertyStr(global, "httpDone");
        defer host.ctx.freeValue(done);
        try std.testing.expect(try host.ctx.toBool(done));
    } else {
        try support.pumpUntilTrue(host, "globalThis.httpDone === true");
        try support.expectString(host, "httpError", "");
        if (options.pool) |scenario| {
            const client = &host.http.inner.?;
            try std.testing.expect(client.connection_pool.used.first == null);
            try std.testing.expectEqual(@as(usize, if (scenario == .concurrent) 8 else if (scenario == .origins) 2 else 1), client.connection_pool.free_len);
            try std.testing.expectEqual(@as(usize, switch (scenario) {
                .reuse, .origins => 1,
                .concurrent => 10,
                else => 2,
            }), peer.connections.load(.acquire));
            try std.testing.expectEqual(@as(usize, switch (scenario) {
                .recover => 3,
                .concurrent => 10,
                else => 2,
            }), peer.requests.load(.acquire));
            if (second) |other| {
                try std.testing.expectEqual(@as(usize, 1), other.connections.load(.acquire));
                try std.testing.expectEqual(@as(usize, 2), other.requests.load(.acquire));
            }
        }
        try host.close();
    }
    try support.expectString(host, "httpError", "");
    try std.testing.expect(host.http.inner == null);
    try std.testing.expectEqual(@as(usize, 0), host.bodies.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.signal_waiters.items.len);
    peer.stop();
    try std.testing.expectEqual(@as(?anyerror, null), peer.failure);
}

/// Drive one gated stream mode: the peer writes its first part, the test sees it in JavaScript, then the peer writes the rest.
fn runStream(mode: Mode) !void {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const peer = try Peer.create(std.testing.allocator, runtime.io(), mode);
    defer peer.destroy();
    const host = support.createHostWith(runtime.io(), "");
    defer support.destroyHost(host);
    peer.wake = &host.wake;
    const global = host.ctx.getGlobalObject();
    defer host.ctx.freeValue(global);
    try host.ctx.setPropertyStr(global, "httpUrl", host.ctx.newString(peer.url));
    try host.ctx.setPropertyStr(global, "httpMode", host.ctx.newString(@tagName(mode)));
    try host.ctx.setPropertyStr(global, "httpError", host.ctx.newString(""));
    try support.eval(host, "native_tools/http-stream.test.js");
    try support.pumpUntilSet(host, &peer.ready);
    try support.pumpUntilTrue(host, "globalThis.httpChunks === 1");
    peer.release.set(host.io);
    try support.pumpUntilTrue(host, "globalThis.httpDone === true");
    try support.expectString(host, "httpError", "");
    const client = &host.http.inner.?;
    host.bodies.reap(host.gpa);
    if (mode == .slow_body) {
        // The canceled body closed its connection, and the unread one still holds its own.
        try std.testing.expectEqual(@as(usize, 1), host.bodies.live.items.len);
        try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);
        try std.testing.expectEqual(@as(usize, 2), peer.connections.load(.acquire));
    } else {
        // A stream read to its end returns its connection to the pool.
        try std.testing.expectEqual(@as(usize, 0), host.bodies.live.items.len);
        try std.testing.expectEqual(@as(usize, 1), client.connection_pool.free_len);
    }
    try host.close();
    try std.testing.expect(host.http.inner == null);
    try std.testing.expectEqual(@as(usize, 0), host.bodies.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    peer.stop();
    try std.testing.expectEqual(@as(?anyerror, null), peer.failure);
}

test "fetch streams a body in chunks and carries a character split across reads" {
    try runStream(.sse);
}

test "a canceled body leaves the pool, and an unread body ends at host close" {
    try runStream(.slow_body);
}

test "fetch rejects invalid arguments without an operation" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.eval("globalThis.httpError = '';", "http-init.js");
    try support.eval(host, "native_tools/http-refuse.test.js");
    try support.pumpUntilTrue(host, "globalThis.httpDone === true");
    try support.expectString(host, "httpError", "");
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
}

test "fetch sends headers and bodies and returns bounded text responses" {
    inline for (.{ .reply, .echo, .redirect, .head, .put, .patch, .delete, .empty, .hints, .missing, .limit, .chunk_limit, .chunked, .close_delimited, .headers_limit, .header_bytes_limit, .close_limit, .utf8 }) |mode| try run(mode, .{});
}

test "fetch refuses oversized bodies and malformed responses" {
    inline for (.{ .oversize, .truncated, .malformed, .bad_status, .compressed, .stall, .slow_body, .partial_head, .upload_stall, .oversized_chunk, .close_oversize, .headers, .header_bytes }) |mode| try run(mode, .{});
}

test "plugin disposal cancels and drains fetch" {
    inline for (.{ .stall, .partial_head, .slow_body, .upload_stall }) |mode| try run(mode, .{ .cleanup = .plugin });
}

test "host close cancels an unscoped fetch and settles its promise" {
    inline for (.{ .stall, .partial_head, .slow_body, .upload_stall }) |mode| try run(mode, .{ .cleanup = .host });
}

test "body close retains an active head or read until its task returns" {
    inline for (.{ .stall, .partial_head, .upload_stall, .slow_body }) |mode| try run(mode, .{ .cleanup = .body });
}

test "run cleanup drains fetch without another owner pump" {
    try run(.slow_body, .{ .cleanup = .tool });
}

test "fetch reports a refused connection without a native error name" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    var listener = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(runtime.io(), .{});
    const port = listener.socket.address.getPort();
    listener.deinit(runtime.io());
    const host = support.createHostWith(runtime.io(), "");
    defer support.destroyHost(host);
    const global = host.ctx.getGlobalObject();
    defer host.ctx.freeValue(global);
    var buffer: [128]u8 = undefined;
    try host.ctx.setPropertyStr(global, "httpUrl", host.ctx.newString(try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/", .{port})));
    try host.ctx.setPropertyStr(global, "httpMode", host.ctx.newString("refused"));
    try host.ctx.setPropertyStr(global, "httpError", host.ctx.newString(""));
    try support.eval(host, "native_tools/http.test.js");
    try support.pumpUntilTrue(host, "globalThis.httpDone === true");
    try support.expectString(host, "httpError", "");
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
}

test "the host shares one client and moves the certificate clock, leaving the first bundle load to std" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const host = support.createHostWith(runtime.io(), "");
    defer support.destroyHost(host);

    // A clock set here stops `std` from ever loading the root bundle, so a fresh client keeps none.
    const client = host.http.acquire(host.gpa, host.io);
    try std.testing.expectEqual(@as(?std.Io.Timestamp, null), client.now);
    try std.testing.expectEqual(@as(usize, 0), client.ca_bundle.map.count());

    // Concurrent workers share one client, so none of them builds a second pool or a second bundle.
    var seen: [4]?*std.http.Client = @splat(null);
    var loaders: std.Io.Group = .init;
    defer loaders.cancel(host.io);
    for (&seen) |*slot| try loaders.concurrent(host.io, struct {
        fn take(h: *Host, out: *?*std.http.Client) void {
            out.* = h.http.acquire(h.gpa, h.io);
        }
    }.take, .{ host, slot });
    try loaders.await(host.io);
    for (seen) |slot| try std.testing.expectEqual(client, slot.?);

    // A pin that outlives the certificate it verified rejects every later rotation.
    client.now = .fromNanoseconds(1);
    _ = host.http.acquire(host.gpa, host.io);
    try std.testing.expect(client.now.?.toSeconds() > 1_700_000_000);
}

test "HTTP benchmark scenarios verify complete responses" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    for ([_]bench.Phase{ .http_reused, .http_fresh, .http_close }) |phase| {
        const harness = try bench.Harness.create(std.testing.allocator, runtime.io(), "", 40, 12, phase);
        defer harness.destroy();
        try harness.start(phase, 1);
        const before = harness.http_peer.?.connections.load(.acquire);
        for (0..5) |_| _ = try harness.step();
        try std.testing.expectEqual(@as(i32, 5), try harness.verify(true));
        try std.testing.expectEqual(@as(usize, if (phase == .http_close) 5 else 0), harness.http_peer.?.connections.load(.acquire) - before);
    }
}

test "HTTP pooling isolates origins, bounds idle connections, and permits concurrent bodies" {
    try run(.reply, .{ .pool = .reuse });
    try run(.reply, .{ .pool = .origins });
    try run(.gated, .{ .pool = .concurrent });
}

test "HTTP pooling discards failed responses and only retries safe stale connections" {
    inline for (.{ .truncated, .redirect, .oversize, .headers }) |mode| try run(mode, .{ .pool = .recover });
    try run(.silent_close, .{ .pool = .stale });
    try run(.silent_close, .{ .pool = .no_replay });
}
