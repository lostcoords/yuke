//! `yuke check`: load the profile as the TUI does, with no terminal, and report every warning and error.

const std = @import("std");
const extensions_mod = @import("../js/extensions.zig");
const Extensions = extensions_mod.Extensions;
const Host = extensions_mod.Host;
const HostError = @import("../js/host.zig").Error;
const driver = @import("../js/driver.zig");

/// The time an async plugin startup gets before the report. A slow startup is a plugin bug, so this bound stays short.
const settle_ms = 2000;

/// The TUI composition, so a `tui` block runs. The last answerer wins, so a startup question gets a denial as in `-p`, and the code after it runs.
pub const boot = driver.boot ++
    \\
    \\import { printInteractionPlugin } from "yuke:internal/interaction";
    \\plugins.use(printInteractionPlugin);
;

/// The history keeps each warning and error once with a repeat count, so the report reads it after the profile settles.
const collect_source =
    \\import { notifications } from "yuke:internal/kernel";
    \\const found = notifications.filter((n) => n.level !== "info");
    \\globalThis.checkErrors = found.filter((n) => n.level === "error").length;
    \\globalThis.checkLines = found.map((n) => {
    \\  const at = n.stack.split("\n").find((line) => line.trim().startsWith("at "));
    \\  return n.source + " · " + n.level + ": " + n.message + (at ? " (" + at.trim() + ")" : "") + (n.count > 1 ? " ×" + n.count : "") + "\n";
    \\}).join("");
    \\globalThis.checkSummary = "yuke check: " + globalThis.checkErrors + " error(s), " + (found.length - globalThis.checkErrors) + " warning(s)\n";
;

/// Load the profile, wait until the host is idle or `settle_ms` passes, and print each warning and error to stderr.
/// Return 1 when an error occurs. Return 0 when no error occurs. It fails when stdout or stderr cannot be written, or when the host cannot read its history.
pub fn run(io: std.Io, extensions: *Extensions) (std.Io.Writer.Error || HostError)!u8 {
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    var out_buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const status = try report(extensions.host, &err.interface, &out.interface);
    try err.interface.flush();
    try out.interface.flush();
    return status;
}

/// Settle the loaded profile, write each warning and error to `err` and the counts to `out`, and return the status.
fn report(host: *Host, err: *std.Io.Writer, out: *std.Io.Writer) (std.Io.Writer.Error || HostError)!u8 {
    settle(host, std.Io.Clock.Timestamp.fromNow(host.io, .{ .raw = .fromMilliseconds(settle_ms), .clock = .awake }));
    try host.evalModule(collect_source, "check.js");
    try writeGlobal(host, err, "checkLines");
    try writeGlobal(host, out, "checkSummary");
    return if (try host.evalInt("globalThis.checkErrors") == 0) 0 else 1;
}

/// Pump until the host has no work or the deadline passes. A script error enters the history, and the wait goes on.
fn settle(host: *Host, deadline: std.Io.Clock.Timestamp) void {
    // A callback that throws on every pump returns before `pumpUntil` reads the deadline, so the loop reads it too.
    while (deadline.durationFromNow(host.io).raw.nanoseconds > 0) return host.pumpUntil(deadline, host, idle) catch |err| switch (err) {
        error.JavaScriptFault => {
            host.postFault(Host.script_source);
            continue;
        },
        // Work past the deadline, such as an MCP server, is not an error.
        error.Timeout, error.Canceled => return,
    };
}

fn idle(host: *Host) bool {
    return !host.hasPending();
}

/// Write the string that `collect_source` left in the global `name`.
fn writeGlobal(host: *Host, w: *std.Io.Writer, comptime name: [:0]const u8) (std.Io.Writer.Error || HostError)!void {
    const value = host.ctx.eval("globalThis." ++ name, "check.js", .{}) catch {
        host.noteFault();
        return error.JavaScriptFault;
    };
    defer host.ctx.freeValue(value);
    const text = host.ctx.toCStringLen(value) catch {
        host.noteFault();
        return error.JavaScriptFault;
    };
    defer host.ctx.freeCString(text.ptr);
    try w.writeAll(text);
}

test "check reports an error in a tui block, which the headless modes never run" {
    var f: extensions_mod.Fixture = undefined;
    try f.open(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "tui-probe", apply(ctx) {
        \\  ctx.inject(["tui"], () => { throw new Error("boom in tui"); });
        \\} });
        \\// A startup question gets a denial, so the error after it still shows.
        \\plugins.use({ name: "asks", async apply(ctx) {
        \\  await ctx.interaction.confirm("start", "start now?");
        \\  throw new Error("after the question");
        \\} });
    , boot);
    defer f.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 1), try report(f.extensions.host, &err.writer, &out.writer));
    errdefer std.debug.print("stderr:\n{s}\n", .{err.written()});
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "tui-probe · error: boom in tui (at "));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "asks · error: after the question") != null);
    try std.testing.expectEqualStrings("yuke check: 2 error(s), 1 warning(s)\n", out.written());
}
