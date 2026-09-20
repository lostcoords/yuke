const support = @import("support.zig");
const std = @import("std");
const Paint = @import("paint.zig").Paint;
const Host = @import("../host.zig").Host;
const loop = @import("../loop.zig");
const engine = @import("../native/engine.zig");
const driver = @import("../driver.zig");
const proto = @import("proto");

test "focused session identity follows pane and session lifetimes" {
    try support.run("app/focused-session.test.js");
}

test "yuke:client exposes the engine surface and answers a closed session" {
    try support.run("app/c.test.js");
}

test "yuke:defaults boots the shell, seeds the session feed, and wires commands" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 24, 80);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    paint.bind(host);

    // The frontend boot provides the terminal capability, so the test boots the same way.
    try support.eval(host, "app/boot.test.js");
    // No engine is attached here, so boot renders the empty chat and its hint.
    try loop.start(host);
    try loop.stepTick(host);
    try loop.flushFrame(host);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "new chat") != null);

    // the command registry and the vim toggle are wired.
    try support.eval(host, "app/act.test.js");
}

test "the notice plugin draws and listens only while it is loaded" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const native_engine = engine;
    // The message object outlives the plugin; only the registrations come and go.
    try support.eval(host, "app/notice.test.js");
    const event_sink = host.engine.eventSink();
    event_sink.on_event(event_sink.ctx, .{ .method = .notice, .params = .{ .notice = .{
        .level = .@"error",
        .source = "agents",
        .message = "terminal write failed",
    } } });
    try std.testing.expect(!native_engine.drain(host.engine, host.ctx));
    try host.eval("globalThis.checkEngineNotice();", "notice-native.js");
}

test "the session feed caches its derived reads until a change" {
    try support.run("app/sessions.test.js");
}

test "the session feed replaces its state after a refresh" {
    try support.run("app/feed-refresh.test.js");
}

test "the command ui registers its palette as one plugin" {
    // The slice owns the palette, so an unload takes the command, the key, and an open overlay.
    try support.run("app/cmdui.test.js");
}

test "the palette lists only the commands that carry metadata" {
    // A keymap target is not a user action, so the palette must skip it and sort the rest by title.
    try support.run("app/meta.test.js");
}

test "an attachment warns when the model it would go to reads no images" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "app/boot-2.test.js");
    try support.eval(host, "app/vision.test.js");
}

test "the slash menu follows the composer, completes, runs, and leaves a message alone" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "app/boot-2.test.js");
    // The float never takes the focus, and the rules for Tab, Enter, Escape, and a plain message all hold.
    try support.eval(host, "app/slash.test.js");
}

test "the auth plugin logs in with a device code or a key, logs out, and guards the model picker" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try host.evalModule(driver.boot, "auth-boot.js");
    // `client` is one object, so the test replaces the auth calls and drives the dialogs with keys.
    try support.eval(host, "app/auth.test.js");
    try host.pump();
    try host.evalModule("await globalThis.authTest;", "auth-result.js");
}

test "the auth device dialog closes for native completion before or after the login response" {
    const native_engine = engine;
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32);
    try host.evalModule(driver.boot, "auth-boot.js");
    try support.eval(host, "app/auth-native.test.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.openCount()"));

    const sink = host.engine.eventSink();
    sink.on_event(sink.ctx, .{ .method = .@"auth.login_finished", .params = .{ .auth_login_finished_data = .{
        .login_id = .bytes([_]u8{7} ** proto.ids.LoginId.byte_len),
        .provider_id = "codex",
        .outcome = .{ .succeeded = .{} },
    } } });
    try std.testing.expect(!native_engine.drain(host.engine, host.ctx));
    try host.drainJobs();
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.openCount()"));

    try host.eval("globalThis.startPendingLogin();", "auth-native-pending.js");
    try host.drainJobs();
    sink.on_event(sink.ctx, .{ .method = .@"auth.login_finished", .params = .{ .auth_login_finished_data = .{
        .login_id = .bytes([_]u8{8} ** proto.ids.LoginId.byte_len),
        .provider_id = "codex",
        .outcome = .{ .succeeded = .{} },
    } } });
    try std.testing.expect(!native_engine.drain(host.engine, host.ctx));
    try host.eval("globalThis.finishPendingLogin();", "auth-native-finish.js");
    try host.drainJobs();
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.openCount()"));
}

test "the activity module reads back on the fact, overlays the chat entry, and an interrupt keeps the queue" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "app/boot-2.test.js");
    try support.eval(host, "app/activity.test.js");
}

test "the indicator, the queue strip, and the context reading follow the live activity" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "app/boot-2.test.js");
    try support.eval(host, "app/indicator.test.js");
}

test "the cache window reads the session totals and the catalog prices" {
    try support.run("app/cache.test.js");
}

test "the palette hints only the strokes that run the command here" {
    // A hint the current context cannot run is worse than no hint, so the scan must rank like dispatch.
    try support.run("app/hint.test.js");
}

test "the catalog stores a full reply and keeps the models on unchanged" {
    // `client` is one object, so a test replaces the one method the branch calls.
    try support.run("app/catload.test.js");
}

test "the explorer turns one directory listing into rows" {
    try support.run("app/explore.test.js");
}

test "the catalog slice owns the model reading" {
    // The readings need the open session, which the shell owns, so the slice takes it as config.
    try support.run("app/catalog.test.js");
}

test "loadCatalog retains its state after a refusal" {
    // Controlled requests exercise shared and follow-up reads, then a refusal.
    try support.run("app/loadcatalog.test.js");
}

test "the chat slice owns its listeners and its transcript commands" {
    // The chat reacts to session events and offers the commands that read its transcript.
    try support.run("app/chat.test.js");
}

test "a split gives each chat pane its own session" {
    // Each pane starts with its own session, and an event reaches every pane that shows the pair.
    try support.run("app/splitchat.test.js");
}

test "the context owns every overlay its plugin pushes" {
    // A modal that outlives its plugin consumes every key, so the scope must own the stack too.
    try support.run("app/ctxoverlay.test.js");
}

test "the explorer registers its command and takes it back on unload" {
    // The picker walks the filesystem through the client, so only its command lifetime is tested here.
    try support.run("app/explorer.test.js");
}

test "a chat retains only successful session pins" {
    try support.run("app/pins.test.js");
}

test "navigation after initial admission neither sends twice nor closes an unowned pin" {
    const host = support.createHostWith(std.testing.io, "/work");
    defer support.destroyHost(host);
    try support.eval(host, "app/navigation.test.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.submitted && globalThis.firstInput === 'first task' && globalThis.chat.sessionId === null"));
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.closes + globalThis.sends"));
    try host.eval("globalThis.chat.dispose()", "dispose.js");
}

test "refresh shares callers through follow-up reads and refusals" {
    try support.run("app/refresh.test.js");
}
