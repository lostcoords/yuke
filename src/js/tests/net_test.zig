const std = @import("std");
const zio = @import("zio");
const support = @import("support.zig");
const Peer = @import("../socket_peer.zig").Peer;

fn run(comptime file: [:0]const u8, mode: Peer.Mode, cleanup_checkpoint: bool) !void {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const peer = try Peer.create(std.testing.allocator, runtime.io(), mode);
    defer peer.destroy();
    const host = support.createHostWith(runtime.io(), "");
    defer support.destroyHost(host);
    const global = host.ctx.getGlobalObject();
    defer host.ctx.freeValue(global);
    try host.ctx.setPropertyStr(global, "socketPath", host.ctx.newString(peer.path));
    try host.ctx.setPropertyStr(global, "socketPeerMode", host.ctx.newString(@tagName(mode)));
    try support.eval(host, file);
    if (cleanup_checkpoint) {
        try support.pumpUntilTrue(host, "globalThis.socketCleanupReady === true");
        const deadline = std.Io.Clock.Timestamp.fromNow(host.io, .{ .raw = .fromSeconds(5), .clock = .awake });
        while (true) {
            host.wake.reset();
            try host.pump();
            if (host.net.live.items.len == 0) break;
            if (deadline.durationFromNow(host.io).raw.nanoseconds <= 0) return error.SocketCleanupTimeout;
            if (host.hasPending()) continue;
            host.wake.waitTimeout(host.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
        }
        try host.eval("globalThis.resumeSocketTest()", "net-resume.js");
    }
    try support.pumpUntilTrue(host, "globalThis.socketDone === true");
    try host.close();
    try std.testing.expectEqual(@as(usize, 0), host.net.live.items.len);
}

test "socket streams preserve bytes and support full duplex" {
    try run("native_tools/net.test.js", .echo, false);
}

test "socket timeouts and cancellation drain stalled operations" {
    try run("native_tools/net-cancel.test.js", .stall, true);
}

test "socket EOF and host shutdown release open connections" {
    try run("native_tools/net-eof.test.js", .eof, false);
}

test "socket benchmark scenarios verify reused and fresh connections" {
    const bench = @import("../bench/bench.zig");
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    for ([_]bench.Phase{ .net_echo, .net_echo_fresh }) |phase| {
        const harness = try bench.Harness.create(std.testing.allocator, runtime.io(), "", 40, 12, phase);
        defer harness.destroy();
        try harness.start(phase, 1);
        for (0..5) |_| {
            _ = try harness.step();
            if (phase == .net_echo_fresh) try std.testing.expectEqual(@as(usize, 0), harness.host.net.live.items.len);
        }
        try std.testing.expectEqual(@as(i32, 5), try harness.verify());
    }
}

test "JSON lines over sockets validate complete bounded UTF-8 frames" {
    try run("native_tools/net-json.test.js", .json_lines, false);
}

test "Herdr plugin reports and clears over real Unix sockets" {
    try run("plugins/herdr-socket.test.js", .herdr, false);
}

test "Herdr plugin bounds stalled reports and shutdown" {
    try run("plugins/herdr-socket.test.js", .stall, false);
}
