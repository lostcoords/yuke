//! The JSONL interaction path runs against a real QuickJS host.

const std = @import("std");
const proto = @import("proto");
const rpc = @import("rpc.zig");
const Host = @import("../js/host.zig").Host;
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
