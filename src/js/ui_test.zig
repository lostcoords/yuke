const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "yuke:core clip and style.resolve" {
    try support.run("tests/ui/core.test.js");
}

test "a tool image shows one label row per blob after the output" {
    try support.runPainted(12, 60, "tests/ui/tool-media.test.js");
}

test "skill messages fold by native identity and preserve their exact text" {
    try support.run("tests/ui/skill-message.test.js");
}

test "yuke:core wrapOffsets keeps every byte and caretRowCol places the caret" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/ui/wrap.test.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.result"));
}

test "yuke:core RootView paints and only ctrl+q quits" {
    var fixture = try support.PaintedHost.init(2, 8);
    defer fixture.deinit();
    const host = fixture.host;

    try support.eval(host, "tests/ui/ui.test.js");
    const loop = @import("loop.zig");
    try loop.start(host);
    try loop.flushFrame(host);
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "hi") != null);
    // A bare key never quits, so a stray key in a modal layer cannot end the session.
    try loop.step(host, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(!host.paint.quit_requested);
    try support.eval(host, "tests/ui/bind.test.js");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'z', .mods = .{ .ctrl = true } } });
    try std.testing.expect(host.paint.suspend_requested);
    try std.testing.expect(!host.paint.quit_requested);
    try loop.step(host, .{ .key_press = .{ .codepoint = 'q', .mods = .{ .ctrl = true } } });
    try std.testing.expect(host.paint.quit_requested);
}

test "yuke:core config validates and TextInput inserts committed text" {
    try support.run("tests/ui/cfg.test.js");
}

test "yuke:ui mouse config, wheel scroll, and pane routing under the pointer" {
    try support.runPainted(10, 21, "tests/ui/mouse.test.js");
}

test "yuke:ui copy writes clipboard data" {
    var fixture = try support.PaintedHost.init(10, 40);
    defer fixture.deinit();
    const host = fixture.host;

    try support.eval(host, "tests/ui/copy.test.js");
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "\x1b]52;c;aGk=\x1b\\") != null);
}

test "yuke:ui drag selection spans rows, copies, and clears on a width change" {
    try support.runPainted(12, 40, "tests/ui/sel.test.js");
}

test "yuke:ui the transcript seam maps a position to source, screen, and scroll" {
    try support.runPainted(8, 20, "tests/ui/seam.test.js");
}

test "yuke:composer-vim moves, edits, and puts in normal mode" {
    try support.run("tests/ui/cvim.test.js");
}

test "yuke:transcript-vim moves a cursor and gives the caret to the transcript" {
    try support.runPainted(20, 24, "tests/ui/tvim.test.js");
}

test "yuke:ui tool parts render, collapse, copy, and toggle" {
    try support.runPainted(12, 40, "tests/ui/ui-components.test.js");
}

test "yuke:ui action groups cross reasoning and full tool fields stay available" {
    try support.run("tests/ui/action-groups.test.js");
}

test "yuke:ui hidden tool deltas keep rows stable and details fresh" {
    try support.run("tests/ui/hidden-deltas.test.js");
}

test "yuke:ui action plans stay aligned after eviction and outline changes" {
    try support.run("tests/ui/action-plan-order.test.js");
}

test "yuke:ui reasoning auto-collapses when assistant text starts and J/K walks parts" {
    try support.runPainted(12, 40, "tests/ui/reason.test.js");
}

test "yuke:md renders the GFM subset and caches finalized blocks" {
    try support.run("tests/ui/md.test.js");
}

test "yuke:md an appended stream parses like a fresh document" {
    try support.run("tests/ui/md-stream.test.js");
}

test "yuke:md maps a rendered row back to its markdown source" {
    try support.run("tests/ui/mdsrc.test.js");
}

test "yuke:ui a selection maps back to the markdown source" {
    try support.runPainted(12, 40, "tests/ui/selsrc.test.js");
}

test "yuke:ui List itemHeight, fzy ranking, and Transcript rows" {
    try support.run("tests/ui/ui-2.test.js");
}

test "yuke:ui Composer grows, pastes in one edit, and owns the vertical keys" {
    try support.run("tests/ui/composer.test.js");
}

test "yuke:ui Transcript draws markdown segments through the pager" {
    var fixture = try support.PaintedHost.init(6, 24);
    defer fixture.deinit();
    const host = fixture.host;

    try support.eval(host, "tests/ui/draw.test.js");
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "there") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "─") != null);
}

test "yuke:ui Composer collapses a large paste and still submits the whole text" {
    try support.run("tests/ui/paste.test.js");
}

test "yuke:ui Composer labels an image span by position and submits content parts" {
    try support.run("tests/ui/image-span.test.js");
}

test "a pasted image path attaches, and every other paste keeps its text" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/ui/attach.test.js");
    try support.pumpUntilIdle(host);
    try support.eval(host, "tests/ui/attach-result.test.js");
}

test "a user message draws its image label where the part sits" {
    try support.run("tests/ui/user-image.test.js");
}

test "the clipboard image attaches and its temporary file never outlives the put" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/ui/clipboard.test.js");
    try support.pumpUntilIdle(host);
    try support.eval(host, "tests/ui/clipboard-result.test.js");
}

test "yuke:ui Composer draws a wrapped row whole and puts the caret on it" {
    var fixture = try support.PaintedHost.init(4, 7);
    defer fixture.deinit();
    const host = fixture.host;

    // The prompt takes two cells of the seven, so "hello world" wraps at five.
    try support.eval(host, "tests/ui/composer_draw.test.js");

    // The hanging space must not turn the row into an ellipsis.
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.paint.out.written(), "…") == null);

    try support.expectString(host, "result", "ok");
}

test "a style link cycle falls back instead of spinning" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/ui/cycle.test.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.result"));
}

test "an overlay without a hook is consumed, not a fault" {
    var fixture = try support.PaintedHost.init(2, 8);
    defer fixture.deinit();
    const host = fixture.host;

    // The overlay implements `draw` and no other hook.
    try support.eval(host, "tests/ui/overlay.test.js");

    const loop = @import("loop.zig");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.seen"));

    try host.eval("globalThis.root.popOverlay();", "pop.js");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen"));
}

test "bordered picker preserves actions padding and mouse targets after resize" {
    try support.runPainted(24, 80, "tests/ui/picker-geometry.test.js");
}

test "an unusable view or layer is rejected at the call" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/ui/reject.test.js");
    try std.testing.expectEqual(@as(i32, 6), try host.evalInt("globalThis.threw"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.cleared"));
}

test "a route sends an event to the keymap before the view" {
    var fixture = try support.PaintedHost.init(2, 8);
    defer fixture.deinit();
    const host = fixture.host;
    const loop = @import("loop.zig");

    // The pane records a "V" when it reads, and the binding records a "K".
    try support.eval(host, "tests/ui/route.test.js");

    const press = struct {
        fn go(h: *Host) !void {
            try loop.step(h, .{ .key_press = .{ .codepoint = 'a' } });
            try h.eval("globalThis.result = globalThis.hits;", "r.js");
        }
    }.go;

    // With no route the view reads first, which is the behavior before a plugin loads.
    try press(host);
    try support.expectString(host, "result", "V");

    // A keymap route skips the view entirely.
    try host.eval("globalThis.d1 = globalThis.route.add(\"keymap\");", "a1.js");
    try press(host);
    try support.expectString(host, "result", "VK");

    // A deeper context outranks the unscoped route.
    try host.eval("globalThis.d2 = globalThis.route.add(\"view\", \"inner\");", "a2.js");
    try press(host);
    try support.expectString(host, "result", "VKV");

    // The disposer uncovers the route it hid.
    try host.eval("globalThis.d2();", "d2.js");
    try press(host);
    try support.expectString(host, "result", "VKVK");

    // Depth ranks over registration order, so the older deep route still wins.
    try support.evalScript(host, "tests/ui/order.test.js");
    try press(host);
    try support.expectString(host, "result", "VKVKV");

    // A keymap route drops a paste, because no pane below it reads the event.
    try host.eval("globalThis.d2();", "d2b.js");
    try loop.stepPaste(host, "x");
    try host.eval("globalThis.result = globalThis.hits;", "r.js");
    try support.expectString(host, "result", "VKVKV");

    // With the route gone the paste reaches the view again.
    try host.eval("globalThis.d1();", "d1.js");
    try loop.stepPaste(host, "x");
    try host.eval("globalThis.result = globalThis.hits;", "r.js");
    try support.expectString(host, "result", "VKVKVV");

    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
}

test "route.add rejects a destination it cannot serve" {
    try support.run("tests/ui/reject-2.test.js");
}

test "the composer route stays off while another pane has focus" {
    const host = support.createHost();
    defer support.destroyHost(host);
    // `composer_vim` reads the mode from any chat, so only the `chat` atom can gate the route.
    try support.eval(host, "tests/ui/route-panes.test.js");
}

test "a pane focus and a terminal focus are separate events" {
    var fixture = try support.PaintedHost.init(4, 16);
    defer fixture.deinit();
    const host = fixture.host;
    const loop = @import("loop.zig");

    // `focus.changed` is the terminal window and `pane.focused` is a leaf inside the layout.
    try support.eval(host, "tests/ui/focus.test.js");

    // The terminal loses and regains focus, which moves no pane.
    try loop.step(host, .focus_in);
    try loop.step(host, .focus_out);
    try host.eval("globalThis.result = globalThis.log;", "r.js");
    try support.expectString(host, "result", "T1T0");

    // A pane focus reports the view that took it.
    try host.eval("globalThis.root.focusView(globalThis.b); globalThis.result = globalThis.log;", "b.js");
    try support.expectString(host, "result", "T1T0Pb");

    // The focused pane stays focused, so a repeat reports nothing.
    try host.eval("globalThis.root.focusView(globalThis.b); globalThis.result = globalThis.log;", "b2.js");
    try support.expectString(host, "result", "T1T0Pb");

    try host.eval("globalThis.root.focusView(globalThis.a); globalThis.result = globalThis.log;", "a.js");
    try support.expectString(host, "result", "T1T0PbPa");
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
}

test "the chat pane names the region that reads the keyboard" {
    try support.run("tests/ui/region.test.js");
}

test "a focused transcript takes the keys even while the composer sits in normal mode" {
    try support.runPainted(20, 24, "tests/ui/both.test.js");
}

test "a slot lets a plugin answer for a widget it does not own" {
    try support.run("tests/ui/slot.test.js");
}

test "composer-vim supplies the prompt glyph through the slot" {
    try support.run("tests/ui/prompt.test.js");
}

test "a modal picker reads the shared nav keys and seals the keymap" {
    // The keys travel through the real dispatch, so the modal boundary is part of the test.
    try support.run("tests/ui/picker.test.js");
}

test "a finder answers the whole picker contract" {
    try support.run("tests/ui/finder.test.js");
}

test "a tickable registered through a plugin leaves when the plugin unloads" {
    try support.run("tests/ui/service.test.js");
}

test "a tickable removed during startup never starts" {
    // One `onStart` can remove a service the pass has not reached, so that service never starts.
    try support.run("tests/ui/startup.test.js");
}

test "the nav vocabulary cannot drift after the shell binds it" {
    // The shell copies the table once and a modal reads it per key, so it must not be writable.
    try support.run("tests/ui/frozen.test.js");
}

test "the pager follows the tail and counts the rows once per frame" {
    try support.runPainted(24, 80, "tests/ui/pager.test.js");
}

test "the chat pane routes a drag that leaves the transcript and guards its press slot" {
    // A drag that ends over the composer must still reach the transcript, or its drag never ends.
    try support.runPainted(20, 40, "tests/ui/mouse-2.test.js");
}

test "yuke:ui transcript renders evicted history exactly" {
    try support.runPainted(12, 32, "tests/ui/transcript-eviction.test.js");
}

test "yuke:ui transcript keeps committed renders across a reload" {
    try support.runPainted(12, 40, "tests/ui/transcript-reload-reuse.test.js");
}

test "yuke:ui transcript retains the closed row prefix across text deltas" {
    try support.run("tests/ui/transcript-row-prefix.test.js");
}
