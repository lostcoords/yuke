//! The JSONL interaction path runs against a real QuickJS host.

const std = @import("std");
const rpc = @import("rpc.zig");
const Host = @import("../js/host.zig").Host;
const extensions_mod = @import("../js/extensions.zig");
const App = @import("app.zig").App;
const ai = @import("ai");
const zio = @import("zio");

const testing = std.testing;

test "an interaction question and its answer share the RPC stream" {
    const host = Host.create(testing.allocator);
    defer host.destroy();
    try host.evalModule(rpc.boot ++
        \\
        \\import { plugins as registry } from "yuke:ext";
        \\registry.use({ name: "ask", apply(ctx) { ctx.interaction.confirm("allow", "run"); } });
    , "rpc-interaction.js");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var notifications = rpc.NotificationQueue{};
    defer rpc.drainNotifications(testing.allocator, &notifications);
    var wake = zio.ResetEvent.init;
    var stream: rpc.Rpc = .{
        .app = undefined,
        .out = &buf.writer,
        .gpa = testing.allocator,
        .notifications = &notifications,
        .wake = &wake,
        .interactions = rpc.interactionPort(&host.interactions),
    };

    stream.flushNotifications();
    try testing.expectEqualStrings(
        "{\"method\":\"interaction.requested\",\"params\":{\"interaction_id\":1,\"request\":{\"type\":\"confirm\",\"title\":\"allow\",\"message\":\"run\"}}}\n",
        buf.written(),
    );
    // A second flush writes nothing, because the question is already sent.
    stream.flushNotifications();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf.written(), "interaction.requested"));

    rpc.serve(testing.allocator, &stream,
        \\{"id":"answer","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"select","value":"b"}}}
    );
    try testing.expect(std.mem.endsWith(u8, buf.written(), "\"code\":-32602,\"message\":\"the interaction response has the wrong type\"}}\n"));

    rpc.serve(testing.allocator, &stream,
        \\{"id":"answer","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"confirm","value":true}}}
    );
    try testing.expect(std.mem.endsWith(u8, buf.written(), "{\"id\":\"answer\",\"result\":{}}\n"));

    rpc.serve(testing.allocator, &stream,
        \\{"id":"late","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"confirm","value":false}}}
    );
    try testing.expect(std.mem.endsWith(u8, buf.written(), "{\"id\":\"late\",\"error\":{\"code\":-31024,\"message\":\"unknown interaction\"}}\n"));
}

test "a pending input hook still accepts an interaction response" {
    var f: extensions_mod.Fixture = undefined;
    try f.init("", rpc.boot);
    defer f.deinit();
    const extensions = &f.extensions;
    try extensions.host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\plugins.use({ name: "gate", apply(ctx) {
        \\  ctx.hook("input.before", async () =>
        \\    await ctx.interaction.confirm("allow", "input") ? undefined : { block: "denied" });
        \\} });
    , "gate.js");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var notifications = rpc.NotificationQueue{};
    defer rpc.drainNotifications(testing.allocator, &notifications);
    var stream: rpc.Rpc = .{
        .app = &f.app,
        .out = &out.writer,
        .gpa = testing.allocator,
        .notifications = &notifications,
        .wake = &extensions.host.wake,
        .interactions = rpc.interactionPort(&extensions.host.interactions),
        .host = extensions.host,
    };
    defer stream.deinit();
    rpc.serve(testing.allocator, &stream,
        \\{"id":"c","method":"session.create","params":{"workspace_path":"/tmp/yuke-rpc-hook"}}
    );
    const Created = struct { result: struct { session: struct { id: []const u8 } } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const created = try std.json.parseFromSliceLeaky(Created, arena.allocator(), out.written(), .{ .ignore_unknown_fields = true });
    const input_line = try std.fmt.allocPrint(arena.allocator(),
        \\{{"id":"input","method":"session.send_input","params":{{"session_id":"{s}","input":{{"type":"content","content":[{{"type":"text","text":"hello"}}]}}}}}}
    , .{created.result.session.id});
    rpc.serve(testing.allocator, &stream, input_line);

    // The gate runs on this pump, and the hook asks its question before the owner returns.
    try extensions.host.pump();
    stream.flushNotifications();
    try testing.expect(std.mem.indexOf(u8, out.written(), "interaction.requested") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"input\"") == null);

    rpc.serve(testing.allocator, &stream,
        \\{"id":"init","method":"initialize"}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"init\",\"result\"") != null);

    rpc.serve(testing.allocator, &stream,
        \\{"id":"answer","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"confirm","value":true}}}
    );
    // The answer settles the hook, then the command, then the gate's Promise: one pump per step.
    for (0..8) |_| {
        try extensions.host.pump();
        stream.drainInputs();
        if (stream.inputs.items.len == 0) break;
    }
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"input\",\"result\"") != null);
}
