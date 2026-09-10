const support = @import("test_support.zig");
const std = @import("std");
const Paint = @import("test_paint.zig").Paint;
const Host = @import("host.zig").Host;

test "yuke:client exposes the engine surface and answers a closed session" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/c.test.js");
}

test "yuke:defaults boots the shell, seeds the session feed, and wires commands" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 24, 80);
    defer paint.deinit();
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    paint.bind(host);

    // The frontend boot provides the terminal capability, so the test boots the same way.
    try support.eval(host, "tests/app/boot.test.js");

    const loop = @import("loop.zig");
    // No engine is attached here, so boot renders the empty chat and its hint.
    try loop.start(host);
    try loop.stepTick(host);
    try loop.flushFrame(host);
    try std.testing.expect(std.mem.indexOf(u8, paint.out.written(), "new chat") != null);

    // the command registry and the vim toggle are wired.
    try support.eval(host, "tests/app/act.test.js");
}

test "the notice plugin draws and listens only while it is loaded" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    const native_engine = @import("native/engine.zig");
    // The message object outlives the plugin; only the registrations come and go.
    try support.eval(host, "tests/app/notice.test.js");
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
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/sessions.test.js");
}

test "the session feed replaces its state after a refresh" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/feed-refresh.test.js");
}

test "the command ui registers its palette as one plugin" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // The slice owns the palette, so an unload takes the command, the key, and an open overlay.
    try support.eval(host, "tests/app/cmdui.test.js");
}

test "the palette lists only the commands that carry metadata" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // A keymap target is not a user action, so the palette must skip it and sort the rest by title.
    try support.eval(host, "tests/app/meta.test.js");
}

test "the slash menu follows the composer, completes, runs, and leaves a message alone" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "tests/app/boot-2.test.js");
    // The float never takes the focus, and the rules for Tab, Enter, Escape, and a plain message all hold.
    try support.eval(host, "tests/app/slash.test.js");
}

test "the auth plugin logs in with a device code or a key, logs out, and guards the model picker" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    host.budget = 2048; // The test settles several dialogs in one module evaluation.
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "tests/app/boot-3.test.js");
    // `client` is one object, so the test replaces the auth calls and drives the dialogs with keys.
    try support.eval(host, "tests/app/auth.test.js");
}

test "the auth device dialog closes for native completion before or after the login response" {
    const proto = @import("proto");
    const native_engine = @import("native/engine.zig");
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32);
    try support.eval(host, "tests/app/auth-native-boot.test.js");
    try support.eval(host, "tests/app/auth-native.test.js");
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
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "tests/app/boot-4.test.js");
    try support.eval(host, "tests/app/activity.test.js");
}

test "the indicator, the queue strip, and the context reading follow the live activity" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    try support.eval(host, "tests/app/boot-5.test.js");
    try support.eval(host, "tests/app/indicator.test.js");
}

test "commands.define registers a user command with a slash word and removes it" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/define.test.js");
}

test "the palette hints only the strokes that run the command here" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // A hint the current context cannot run is worse than no hint, so the scan must rank like dispatch.
    try support.eval(host, "tests/app/hint.test.js");
}

test "the catalog stores a full reply and keeps the models on unchanged" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // `client` is one object, so a test replaces the one method the branch calls.
    try support.eval(host, "tests/app/catload.test.js");
}

test "the explorer turns one directory listing into rows" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/explore.test.js");
}

test "the catalog slice owns the model reading" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // The readings need the open session, which the shell owns, so the slice takes it as config.
    try support.eval(host, "tests/app/catalog.test.js");
}

test "loadCatalog retains its state after a refusal" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // Controlled requests exercise shared and follow-up reads, then a refusal.
    try support.eval(host, "tests/app/loadcatalog.test.js");
}

test "the chat slice owns its listeners and its transcript commands" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // The chat reacts to session events and offers the commands that read its transcript.
    try support.eval(host, "tests/app/chat.test.js");
}

test "a split gives each chat pane its own session" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // Each pane starts with its own session, and an event reaches every pane that shows the pair.
    try support.eval(host, "tests/app/splitchat.test.js");
}

test "the context owns every overlay its plugin pushes" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // A modal that outlives its plugin consumes every key, so the scope must own the stack too.
    try support.eval(host, "tests/app/ctxoverlay.test.js");
}

test "the explorer registers its command and takes it back on unload" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    // The picker walks the filesystem through the client, so only its command lifetime is tested here.
    try support.eval(host, "tests/app/explorer.test.js");
}

test "a chat retains only successful session pins" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/pins.test.js");
}

test "navigation after initial admission neither sends twice nor closes an unowned pin" {
    const host = Host.createTest(std.testing.allocator, std.testing.io, "/work");
    defer host.destroy();
    try support.eval(host, "tests/app/navigation.test.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.submitted && globalThis.firstInput === 'first task' && globalThis.chat.sessionId === null"));
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.closes + globalThis.sends"));
    try host.eval("globalThis.chat.dispose()", "dispose.js");
}

test "refresh shares callers through follow-up reads and refusals" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/app/refresh.test.js");
}
