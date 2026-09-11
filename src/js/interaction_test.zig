const support = @import("test_support.zig");
const std = @import("std");
const Paint = @import("test_paint.zig").Paint;
const Host = @import("host.zig").Host;

test "RPC interaction answers correlated promises out of order" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/interaction/interaction.test.js");

    // The host refuses an answer to a question the frontend has not seen.
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{
        .interaction_id = 1,
        .response = .{ .confirm = .{ .value = true } },
    }));
    const first = host.interactions.takeNext().?;
    try std.testing.expectEqualStrings("first", first.request.confirm.title);
    const second = host.interactions.takeNext().?;
    try std.testing.expectEqualStrings("second", second.request.select.title);
    try std.testing.expect(host.interactions.takeNext() == null);

    try std.testing.expectError(error.InvalidSelection, host.interactions.respond(.{
        .interaction_id = second.interaction_id,
        .response = .{ .select = .{ .value = "green" } },
    }));
    try std.testing.expectError(error.ResponseMismatch, host.interactions.respond(.{
        .interaction_id = second.interaction_id,
        .response = .{ .input = .{ .value = "blue" } },
    }));
    try host.interactions.respond(.{
        .interaction_id = second.interaction_id,
        .response = .{ .select = .{ .value = "blue" } },
    });
    try host.interactions.respond(.{
        .interaction_id = first.interaction_id,
        .response = .{ .confirm = .{ .value = true } },
    });
    try host.pump();
    try support.expectString(host, "result", "[true,\"blue\"]");
}

test "disposing an interaction consumer cancels only its pending dialog" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/interaction/interaction-cancel.test.js");
    const interaction_id = host.interactions.takeNext().?.interaction_id;

    try support.eval(host, "tests/interaction/interaction-dispose.test.js");
    try host.pump();
    try support.expectString(host, "result", "canceled");
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{
        .interaction_id = interaction_id,
        .response = .{ .input = .{ .value = "late" } },
    }));
}

test "the TUI interaction provider answers select and input dialogs" {
    var paint: Paint = undefined;
    try paint.setup(std.testing.allocator, 12, 50);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);
    try support.eval(host, "tests/interaction/interaction-tui.test.js");

    const loop = @import("loop.zig");
    try loop.start(host);
    try loop.step(host, .{ .key_press = .{ .codepoint = '\r' } });
    try loop.step(host, .{ .key_press = .{ .codepoint = 'x' } });
    try loop.step(host, .{ .key_press = .{ .codepoint = '\r' } });
    try support.expectString(host, "result", "alpha:x");
}

test "a composition with no answerer refuses every question" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/interaction/no-answerer.test.js");
    try host.pump();
    try support.expectString(host, "result", "InteractionUnavailable:InteractionUnavailable");
}

test "an install replaces the answerer and its disposer restores the last one" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/interaction/install-stack.test.js");
}
