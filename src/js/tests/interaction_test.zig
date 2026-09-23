const support = @import("support.zig");
const std = @import("std");
const Host = @import("../host.zig").Host;
const loop = @import("../loop.zig");

test "RPC interaction answers correlated promises out of order" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "interaction/interaction.test.js");
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("interactionPending()"));

    // The host refuses an answer to a question the frontend has not seen.
    try std.testing.expectError(error.UnknownInteraction, host.interactions.respond(.{
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
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("interactionPending()"));
}

test "disposing an interaction consumer cancels only its pending dialog" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "interaction/interaction-cancel.test.js");
    const interaction_id = host.interactions.takeNext().?.interaction_id;

    try support.eval(host, "interaction/interaction-dispose.test.js");
    try host.pump();
    try support.expectString(host, "result", "canceled");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("interactionPending()"));
    try std.testing.expectError(error.UnknownInteraction, host.interactions.respond(.{
        .interaction_id = interaction_id,
        .response = .{ .input = .{ .value = "late" } },
    }));
}

test "the TUI interaction provider answers select and input dialogs" {
    var fixture = try support.PaintedHost.init(12, 50);
    defer fixture.deinit();
    const host = fixture.host;
    try support.eval(host, "interaction/interaction-tui.test.js");
    try loop.start(host);
    try loop.step(host, .{ .key_press = .{ .codepoint = '\r' } });
    try loop.step(host, .{ .key_press = .{ .codepoint = 'x' } });
    try loop.step(host, .{ .key_press = .{ .codepoint = '\r' } });
    try support.expectString(host, "result", "alpha:x");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("interactionPending()"));
}

test "a composition with no answerer refuses every question" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "interaction/no-answerer.test.js");
    try host.pump();
    try support.expectString(host, "result", "InteractionUnavailable:InteractionUnavailable");
}

test "an install replaces the answerer and its disposer restores the last one" {
    try support.run("interaction/install-stack.test.js");
}

test "shared interactions own the count across request and frontend lifetimes" {
    try support.run("interaction/lifecycle.test.js");
}

test "TUI interactions close on owner disposal, frontend disposal, and login failure" {
    var fixture = try support.PaintedHost.init(12, 50);
    defer fixture.deinit();
    try support.eval(fixture.host, "interaction/tui-lifecycle.test.js");
}

test "RPC frontend disposal and device login share the interaction lifecycle" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "interaction/rpc-lifecycle.test.js");
    try host.pump();
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
}
