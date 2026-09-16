//! The JSONL interaction path runs against a real QuickJS host.

const std = @import("std");
const rpc = @import("rpc.zig");
const Host = @import("../js/host.zig").Host;
const extensions_mod = @import("../js/extensions.zig");
const App = @import("app.zig").App;
const ai = @import("ai");

const testing = std.testing;

test "an interaction question and its answer share the RPC stream" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(rpc.boot ++
        \\
        \\import { plugins as registry } from "yuke:ext";
        \\registry.use({ name: "ask", apply(ctx) { ctx.interaction.confirm("allow", "run"); } });
    , "rpc-interaction.js");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var notifications = rpc.NotificationQueue{};
    defer rpc.drainNotifications(testing.allocator, &notifications);
    var stream: rpc.Rpc = .{
        .app = undefined,
        .out = &buf.writer,
        .gpa = testing.allocator,
        .notifications = &notifications,
        .host = host,
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
        .host = extensions.host,
    };
    defer stream.deinit();
    rpc.serve(testing.allocator, &stream,
        \\{"id":"c","method":"session.create","params":{"workspace_path":"/tmp/yuke-rpc-hook","model":"test/model"}}
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

test "RPC lists, reads, and stops a background job, and hears its start and its end" {
    var f: extensions_mod.Fixture = undefined;
    try f.init("", rpc.boot);
    defer f.deinit();
    const host = f.extensions.host;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var notifications = rpc.NotificationQueue{};
    defer rpc.drainNotifications(testing.allocator, &notifications);
    var stream: rpc.Rpc = .{ .app = &f.app, .out = &out.writer, .gpa = testing.allocator, .notifications = &notifications, .host = host };
    defer stream.deinit();
    f.app.engine.sinks.add(.{ .ctx = @ptrCast(&stream), .on_event = rpc.Rpc.onEvent });
    defer f.app.engine.sinks.remove(@ptrCast(&stream));

    try host.evalModule(
        \\import { start } from "yuke:jobs";
        \\globalThis.started = 0;
        \\start("echo hello; sleep 30", { root: "/tmp", sessionId: "01010101010101010101010101010101" }).then(() => { started = 1; });
    , "rpc-job.js");
    try support.pumpUntilTrue(host, "globalThis.started === 1");
    stream.flushNotifications();
    try testing.expect(std.mem.indexOf(u8, out.written(), "{\"method\":\"job.changed\",\"params\":{\"job\":{\"id\":1,\"session_id\":\"01010101010101010101010101010101\",\"command\":\"echo hello; sleep 30\",\"cwd\":\"/tmp\",\"state\":\"running\"") != null);

    rpc.serve(testing.allocator, &stream,
        \\{"id":"list","method":"job.list","params":{"session_id":"01010101010101010101010101010101"}}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "{\"id\":\"list\",\"result\":{\"jobs\":[{\"id\":1,") != null);
    rpc.serve(testing.allocator, &stream,
        \\{"id":"other","method":"job.list","params":{"session_id":"02020202020202020202020202020202"}}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "{\"id\":\"other\",\"result\":{\"jobs\":[]}}") != null);

    // The shell writes before the read sees it, so the read retries until the line arrives.
    for (0..100) |_| {
        rpc.serve(testing.allocator, &stream,
            \\{"id":"read","method":"job.read","params":{"id":1,"offset":0,"max_bytes":1024}}
        );
        if (std.mem.indexOf(u8, out.written(), "{\"id\":\"read\",\"result\":{\"text\":\"hello\\n\",\"next\":6,\"size\":6}}") != null) break;
        try f.reactor.io().sleep(.fromMilliseconds(20), .awake);
    } else return error.TestUnexpectedResult;
    rpc.serve(testing.allocator, &stream,
        \\{"id":"big","method":"job.read","params":{"id":1,"offset":0,"max_bytes":262145}}
    );
    try testing.expect(std.mem.endsWith(u8, out.written(), "{\"id\":\"big\",\"error\":{\"code\":-32602,\"message\":\"bad parameters\"}}\n"));
    rpc.serve(testing.allocator, &stream,
        \\{"id":"gone","method":"job.stop","params":{"id":9}}
    );
    try testing.expect(std.mem.endsWith(u8, out.written(), "{\"id\":\"gone\",\"error\":{\"code\":-31029,\"message\":\"unknown job\"}}\n"));

    rpc.serve(testing.allocator, &stream,
        \\{"id":"stop","method":"job.stop","params":{"id":1}}
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "{\"id\":\"stop\",\"result\":{\"job\":{\"id\":1,") != null);
    try host.evalModule("import { events } from \"yuke:kernel\"; globalThis.ended = 0; events.on(\"jobs.changed\", (job) => { if (job.state === \"stopped\") ended = 1; });", "rpc-job-end.js");
    try support.pumpUntilTrue(host, "globalThis.ended === 1");
    stream.flushNotifications();
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"state\":\"stopped\",\"signal\":15,") != null);
}

const support = @import("../js/test_support.zig");
