//! Measure the TUI frame cost against a `yuke --daemon` that serves a seeded store.

const std = @import("std");
const zio = @import("zio");
const term_pkg = @import("term");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const tui_loop = @import("loop.zig");
const term_module = @import("modules/term.zig");
const owner = @import("owner.zig");

const Msg = owner.Msg;
const Channel = owner.Channel;

const frames: u32 = 300;
const reps: u32 = 5;
const bench_cols: u16 = 120;
const bench_rows: u16 = 40;
const connect_timeout_ms: u64 = 10_000;

/// The cost of one frame, split so a change lands against the part it claims to move.
const Result = struct {
    /// One tick event: dispatch, `tickLayers`, the JavaScript draw, and the commit.
    ns_tick: u64,
    /// The JavaScript draw and the commit, without the event dispatch.
    ns_draw: u64,
    /// The commit alone: the cell diff and the terminal write.
    ns_commit: u64,
    /// A frame that scrolls the transcript, so the row source rebuilds the visible rows.
    ns_scroll: u64,
    /// `term.text` and `term.fill` calls in one frame.
    draw_calls: u32,
    /// Bytes one unchanged frame writes.
    steady_bytes: u64,
    /// Messages in the open session, and the rows the transcript wraps them to.
    messages: u32,
    rows: u32,
};

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer rt.deinit();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;

    const r = try measure(init.gpa, rt.io(), init.environ_map);
    const per_tick = r.ns_tick / frames;

    try out.print("yuke TUI bench — {d}x{d}, {d} messages, {d} wrapped rows\n\n", .{ bench_cols, bench_rows, r.messages, r.rows });
    try out.print("  tick frame        {d:>8} us   ({d}/s)\n", .{ per_tick / 1000, @as(u64, std.time.ns_per_s) / @max(per_tick, 1) });
    try out.print("    draw + commit   {d:>8} us\n", .{r.ns_draw / frames / 1000});
    try out.print("    commit alone    {d:>8} us\n", .{r.ns_commit / frames / 1000});
    try out.print("  scrolling frame   {d:>8} us\n", .{r.ns_scroll / frames / 1000});
    try out.print("  draw calls/frame  {d:>8}\n", .{r.draw_calls});
    try out.print("  unchanged frame   {d:>8} bytes   (want 0)\n", .{r.steady_bytes / frames});
    try out.flush();
}

/// Run `step` and print the script fault text before it fails, so a broken probe is debuggable.
fn report(host: *Host, step: host_mod.Error!void) !void {
    step catch |err| {
        std.log.err("bench: {t}: {s}", .{ err, host.faultText() });
        return err;
    };
}

/// Drain the owner queue, then return true once `probe` evaluates to 1.
fn pump(host: *Host, ch: *Channel, io: std.Io, probe: [:0]const u8, timeout_ms: u64) !bool {
    const start = std.Io.Clock.now(.awake, io);
    while (true) {
        while (ch.tryReceive()) |m| {
            var msg = m;
            switch (msg) {
                .daemon => |*d| {
                    defer msg.deinit(host.gpa);
                    try report(host, host.client.onDaemon(host, d));
                },
                else => msg.deinit(host.gpa),
            }
        } else |_| {}

        if (try host.evalInt(probe) == 1) return true;
        const waited: u64 = @intCast(start.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds);
        if (waited / std.time.ns_per_ms > timeout_ms) return false;
        try zio.sleep(.fromMilliseconds(5));
    }
}

/// Boot the baked UI, connect to the daemon, open the largest session, then measure.
fn measure(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !Result {
    var setup: std.Io.Writer.Discarding = .init(&.{});
    var render = try term_pkg.Render.init(io, gpa, env, .{});
    defer render.deinit(&setup.writer);
    try render.resize(&setup.writer, .{ .rows = bench_rows, .cols = bench_cols, .x_pixel = 0, .y_pixel = 0 });

    var counter: std.Io.Writer.Discarding = .init(&.{});
    const host = try Host.createWith(gpa, io, .{ .cwd = "/tmp" });
    defer host.destroy();
    host.bindRender(&render, &counter.writer);

    var slot: [64]Msg = undefined;
    var ch = Channel.init(&slot);
    host.client.bind(&ch);
    defer {
        host.client.stopReaders();
        ch.close(.immediate);
    }

    // The baked graph is trusted, so its compile and run are not bounded, the same as `app.run`.
    host.interrupt_budget = std.math.maxInt(u32);
    try report(host, host.evalModule("import \"yuke:defaults\";", "boot.js"));
    try report(host, host.evalModule(
        \\import { root, style } from "yuke:core";
        \\import { term } from "yuke:term";
        \\import { sidebar, chat } from "yuke:defaults";
        \\import * as client from "yuke:client";
        \\globalThis.__connected = () => (client.connectionState("local") === "ready" ? 1 : 0);
        \\// The sidebar fills from the session list, so a row means the feed arrived.
        \\globalThis.__listed = () => {
        \\  root.invalidate();
        \\  globalThis.flushFrame();
        \\  return (sidebar.list.items || []).length > 0 ? 1 : 0;
        \\};
        \\// Open the session with the most messages, so the transcript holds real content.
        \\globalThis.__openBiggest = () => {
        \\  let best = null;
        \\  for (const r of sidebar.list.items || []) {
        \\    if (!best || r.session.message_count > best.session.message_count) best = r;
        \\  }
        \\  if (!best) return 0;
        \\  sidebar.open(best, "go");
        \\  return best.session.message_count;
        \\};
        \\globalThis.__loaded = () => (chat.transcript.rowCount(term.width) > 20 ? 1 : 0);
        \\globalThis.__rows = () => chat.transcript.rowCount(term.width);
        \\globalThis.__frames = (n) => {
        \\  for (let i = 0; i < n; i++) { root.invalidate(); globalThis.flushFrame(); }
        \\  return 0;
        \\};
        \\// Scroll one row per frame, so the pager rebuilds the visible rows every frame.
        \\globalThis.__scroll = (n) => {
        \\  for (let i = 0; i < n; i++) {
        \\    chat.transcript.pager.scrollBy(i % 2 === 0 ? 1 : -1);
        \\    root.invalidate();
        \\    globalThis.flushFrame();
        \\  }
        \\  return 0;
        \\};
        \\// Row generation alone: wrap, markdown, and segment building, with no drawing.
        \\globalThis.__rowsOnly = (n) => {
        \\  const h = chat.transcript.pager.rect() ? chat.transcript.pager.rect().h : 30;
        \\  for (let i = 0; i < n; i++) chat.transcript.rows(term.width, i % 100, h);
        \\  return 0;
        \\};
        \\globalThis.__ablate = (what, n) => {
        \\  const sd = sidebar.draw, cd = chat.view.draw;
        \\  if (what === "sidebar") sidebar.draw = () => {};
        \\  if (what === "chat") chat.view.draw = () => {};
        \\  for (let i = 0; i < n; i++) { root.invalidate(); globalThis.flushFrame(); }
        \\  sidebar.draw = sd; chat.view.draw = cd;
        \\  return 0;
        \\};
        \\// Count each native call of one frame, so the boundary cost is attributable.
        \\globalThis.__counts = null;
        \\globalThis.__drawCalls = () => {
        \\  const orig = { text: term.text, fill: term.fill, measure: term.measure, graphemes: term.graphemes };
        \\  const c = { text: 0, fill: 0, measure: 0, graphemes: 0, measureChars: 0 };
        \\  term.text = (...a) => { c.text++; return orig.text.apply(term, a); };
        \\  term.fill = (...a) => { c.fill++; return orig.fill.apply(term, a); };
        \\  term.measure = (s) => { c.measure++; c.measureChars += String(s).length; return orig.measure.call(term, s); };
        \\  term.graphemes = (s) => { c.graphemes++; return orig.graphemes.call(term, s); };
        \\  root.invalidate();
        \\  globalThis.flushFrame();
        \\  term.text = orig.text; term.fill = orig.fill;
        \\  term.measure = orig.measure; term.graphemes = orig.graphemes;
        \\  globalThis.__counts = c;
        \\  return c.text + c.fill;
        \\};
        \\// One term.measure call on a short ASCII string, the shape the draw path uses most.
        \\globalThis.__measureCost = (n) => {
        \\  let t = 0;
        \\  for (let i = 0; i < n; i++) t += term.measure("commit");
        \\  return t > 0 ? 0 : 1;
        \\};
        \\// Replace the native measure with a memo, to price the 4853 boundary crossings.
        \\globalThis.__memoFrames = (n) => {
        \\  const orig = term.measure;
        \\  const cache = new Map();
        \\  term.measure = (s) => {
        \\    let w = cache.get(s);
        \\    if (w === undefined) { w = orig.call(term, s); cache.set(s, w); }
        \\    return w;
        \\  };
        \\  for (let i = 0; i < n; i++) { root.invalidate(); globalThis.flushFrame(); }
        \\  term.measure = orig;
        \\  return 0;
        \\};
        \\// One term.text call with a resolved style, the exact shape the draw path uses.
        \\globalThis.__textCost = (n) => {
        \\  const st = style.resolve("Normal");
        \\  term.beginFrame();
        \\  for (let i = 0; i < n; i++) term.text(0, i % 30, "hello world", st);
        \\  term.endFrame();
        \\  return 0;
        \\};
        \\globalThis.__count = (k) => (globalThis.__counts ? globalThis.__counts[k] : 0);
    , "bench-probe.js"));

    try report(host, tui_loop.start(host));

    if (!try pump(host, &ch, io, "__connected()", connect_timeout_ms)) return error.DaemonNotReady;
    if (!try pump(host, &ch, io, "__listed()", connect_timeout_ms)) return error.NoSessions;
    const messages = try host.evalInt("__openBiggest()");
    if (messages == 0) return error.NoSessions;
    if (!try pump(host, &ch, io, "__loaded()", connect_timeout_ms)) return error.TranscriptEmpty;

    const rows = try host.evalInt("__rows()");
    const draw_calls = try host.evalInt("__drawCalls()");

    const before = counter.fullCount();
    try tui_loop.stepTick(host);
    const first_bytes = counter.fullCount() - before;

    // Keep the fastest repetition. A mean tracks the machine's noise, not the code.
    var ns_tick: u64 = std.math.maxInt(u64);
    var ns_draw: u64 = std.math.maxInt(u64);
    var ns_commit: u64 = std.math.maxInt(u64);
    var ns_scroll: u64 = std.math.maxInt(u64);
    var steady_bytes: u64 = 0;
    for (0..reps) |rep| {
        const t0 = std.Io.Clock.now(.awake, io);
        for (0..frames) |_| try tui_loop.stepTick(host);
        const t1 = std.Io.Clock.now(.awake, io);
        if (rep == 0) steady_bytes = counter.fullCount() - before - first_bytes;

        _ = try host.evalInt("__frames(" ++ std.fmt.comptimePrint("{d}", .{frames}) ++ ")");
        const t2 = std.Io.Clock.now(.awake, io);

        // Force the commit past its clean-frame exit, so this measures the diff and the write.
        for (0..frames) |_| {
            host.paint.dirty = true;
            term_module.commitFrame(host);
        }
        const t3 = std.Io.Clock.now(.awake, io);

        _ = try host.evalInt("__scroll(" ++ std.fmt.comptimePrint("{d}", .{frames}) ++ ")");
        const t4 = std.Io.Clock.now(.awake, io);

        ns_tick = @min(ns_tick, elapsed(t0, t1));
        ns_draw = @min(ns_draw, elapsed(t1, t2));
        ns_commit = @min(ns_commit, elapsed(t2, t3));
        ns_scroll = @min(ns_scroll, elapsed(t3, t4));
    }

    {
        inline for (.{ "text", "fill", "measure", "graphemes", "measureChars" }) |k| {
            std.debug.print("  calls {s: <13} {d:>7}\n", .{ k, try host.evalInt("__count('" ++ k ++ "')") });
        }
        const q0 = std.Io.Clock.now(.awake, io);
        _ = try host.evalInt("__frames(" ++ std.fmt.comptimePrint("{d}", .{frames}) ++ ")");
        const q1 = std.Io.Clock.now(.awake, io);
        _ = try host.evalInt("__memoFrames(" ++ std.fmt.comptimePrint("{d}", .{frames}) ++ ")");
        const q2 = std.Io.Clock.now(.awake, io);
        std.debug.print("  draw, native measure {d:>6} us/frame\n", .{elapsed(q0, q1) / frames / 1000});
        std.debug.print("  draw, memoized       {d:>6} us/frame\n", .{elapsed(q1, q2) / frames / 1000});
        const x0 = std.Io.Clock.now(.awake, io);
        _ = try host.evalInt("__textCost(200000)");
        const x1 = std.Io.Clock.now(.awake, io);
        std.debug.print("  one text() call  {d:>6} ns   ({d} us for 461 calls)\n", .{ elapsed(x0, x1) / 200000, elapsed(x0, x1) / 200000 * 461 / 1000 });
        const m0 = std.Io.Clock.now(.awake, io);
        _ = try host.evalInt("__measureCost(100000)");
        const m1 = std.Io.Clock.now(.awake, io);
        std.debug.print("  one measure()    {d:>6} ns   ({d} us for 4853 calls)\n", .{ elapsed(m0, m1) / 100000, elapsed(m0, m1) / 100000 * 4853 / 1000 });
        const c0 = std.Io.Clock.now(.awake, io);
        _ = try host.evalInt("__rowsOnly(" ++ std.fmt.comptimePrint("{d}", .{frames}) ++ ")");
        const c1 = std.Io.Clock.now(.awake, io);
        std.debug.print("  rows() only      {d:>6} us/frame\n", .{elapsed(c0, c1) / frames / 1000});
        inline for (.{ "none", "sidebar", "chat" }) |what| {
            const a0 = std.Io.Clock.now(.awake, io);
            _ = try host.evalInt("__ablate('" ++ what ++ "', " ++ std.fmt.comptimePrint("{d}", .{frames}) ++ ")");
            const a1 = std.Io.Clock.now(.awake, io);
            std.debug.print("  ablate {s: <8} {d:>6} us/frame\n", .{ what, elapsed(a0, a1) / frames / 1000 });
        }
    }

    return .{
        .ns_tick = ns_tick,
        .ns_draw = ns_draw,
        .ns_commit = ns_commit,
        .ns_scroll = ns_scroll,
        .draw_calls = @intCast(draw_calls),
        .steady_bytes = steady_bytes,
        .messages = @intCast(messages),
        .rows = @intCast(rows),
    };
}

fn elapsed(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    return @intCast(from.durationTo(to).nanoseconds);
}
