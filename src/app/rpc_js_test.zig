//! The JSONL interaction path runs against a real QuickJS host.

const std = @import("std");
const rpc = @import("rpc.zig");
const Host = @import("../js/host.zig").Host;
const extensions_mod = @import("../js/extensions.zig");
const App = @import("app.zig").App;
const ai = @import("ai");
const proto = @import("proto");

const testing = std.testing;

const TestFixture = struct {
    fixture: extensions_mod.Fixture,
    out: std.Io.Writer.Allocating,
    notifications: rpc.NotificationQueue,
    stream: rpc.Rpc,

    fn init(self: *TestFixture) !void {
        try self.fixture.init("", rpc.boot);
        self.out = .init(testing.allocator);
        self.notifications = .{};
        self.stream = .{ .app = &self.fixture.app, .out = &self.out.writer, .gpa = testing.allocator, .notifications = &self.notifications, .host = self.fixture.extensions.host };
    }

    /// Pump until every held input answers. A hook settles on one pump and its command runs on the drain.
    fn settleInputs(self: *TestFixture) !void {
        for (0..8) |_| {
            try self.fixture.extensions.host.pump();
            self.stream.drainInputs();
            if (self.stream.inputs.items.len == 0) return;
        }
        return error.TestUnexpectedResult;
    }

    fn deinit(self: *TestFixture) void {
        self.stream.deinit();
        rpc.drainNotifications(testing.allocator, &self.notifications);
        self.out.deinit();
        self.fixture.deinit();
    }
};

const support = @import("../js/tests/support.zig");
const database = @import("../store/store.zig");

test "an interaction question and its answer share the RPC stream" {
    var f: TestFixture = undefined;
    try f.init();
    defer f.deinit();
    const host = f.fixture.extensions.host;
    try host.evalModule(
        \\
        \\import { plugins as registry } from "yuke:internal/ext";
        \\registry.use({ name: "ask", apply(ctx) { ctx.interaction.confirm("allow", "run"); } });
    , "rpc-interaction.js");

    f.stream.flushNotifications();
    try testing.expectEqualStrings(
        "{\"method\":\"interaction.requested\",\"params\":{\"interaction_id\":1,\"request\":{\"type\":\"confirm\",\"title\":\"allow\",\"message\":\"run\"}}}\n",
        f.out.written(),
    );
    // A second flush writes nothing, because the question is already sent.
    f.stream.flushNotifications();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, f.out.written(), "interaction.requested"));

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"answer","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"select","value":"b"}}}
    );
    try testing.expect(std.mem.endsWith(u8, f.out.written(), "\"code\":-32602,\"message\":\"the interaction response has the wrong type\"}}\n"));

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"answer","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"confirm","value":true}}}
    );
    try testing.expect(std.mem.endsWith(u8, f.out.written(), "{\"id\":\"answer\",\"result\":{}}\n"));

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"late","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"confirm","value":false}}}
    );
    try testing.expect(std.mem.endsWith(u8, f.out.written(), "{\"id\":\"late\",\"error\":{\"code\":-31024,\"message\":\"unknown interaction\"}}\n"));
}

test "a pending input hook still accepts an interaction response" {
    var f: TestFixture = undefined;
    try f.init();
    defer f.deinit();
    const extensions = &f.fixture.extensions;
    try extensions.host.evalModule(
        \\import { plugins } from "yuke:internal/ext";
        \\plugins.use({ name: "gate", apply(ctx) {
        \\  ctx.hook("input.before", async () =>
        \\    await ctx.interaction.confirm("allow", "input") ? undefined : { block: "denied" });
        \\} });
    , "gate.js");

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"c","method":"session.create","params":{"workspace_path":"/tmp/yuke-rpc-hook","model":"test/model"}}
    );
    const Created = struct { result: struct { session: struct { id: []const u8 } } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const created = try std.json.parseFromSliceLeaky(Created, arena.allocator(), f.out.written(), .{ .ignore_unknown_fields = true });
    const input_line = try std.fmt.allocPrint(arena.allocator(),
        \\{{"id":"input","method":"session.send_input","params":{{"session_id":"{s}","input":{{"type":"content","content":[{{"type":"text","text":"hello"}}]}}}}}}
    , .{created.result.session.id});
    rpc.serve(testing.allocator, &f.stream, input_line);

    // The gate runs on this pump, and the hook asks its question before the owner returns.
    try extensions.host.pump();
    f.stream.flushNotifications();
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "interaction.requested") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\"id\":\"input\"") == null);

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"init","method":"initialize"}
    );
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\"id\":\"init\",\"result\"") != null);

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"answer","method":"interaction.respond","params":{"interaction_id":1,"response":{"type":"confirm","value":true}}}
    );
    try f.settleInputs();
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\"id\":\"input\",\"result\"") != null);
}

test "a hooked create gates its initial input, and a refusal leaves no session" {
    var f: TestFixture = undefined;
    try f.init();
    defer f.deinit();
    const host = f.fixture.extensions.host;
    try host.evalModule(
        \\import { plugins } from "yuke:internal/ext";
        \\globalThis.mode = "block";
        \\plugins.use({ name: "initial", apply(ctx) {
        \\  ctx.hook("input.before", async (value) => {
        \\    globalThis.proposed = value.session_id === null && value.create.workspace_path === "/work" && value.create.initial_input === undefined;
        \\    if (globalThis.mode === "block") return { block: "denied" };
        \\    if (globalThis.mode === "bad") return { replace: {} };
        \\    return { replace: { content: [{ type: "text", text: "replaced" }] } };
        \\  });
        \\} });
    , "initial.js");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line =
        \\{"id":"c","method":"session.create","params":{"workspace_path":"/work","model":"test/model","initial_input":{"type":"content","content":[{"type":"text","text":"original"}]}}}
    ;
    for ([_][:0]const u8{ "globalThis.mode = 'block'", "globalThis.mode = 'bad'" }) |script| {
        try host.eval(script, "mode.js");
        f.out.clearRetainingCapacity();
        rpc.serve(testing.allocator, &f.stream, line);
        try f.settleInputs();
        try testing.expect(std.mem.startsWith(u8, f.out.written(), "{\"id\":\"c\",\"error\":{\"code\":-32602,"));
        try testing.expectEqual(@as(u64, 0), try database.session.count(&f.fixture.app.db, a, .{}));
    }
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.proposed ? 1 : 0"));

    try host.eval("globalThis.mode = 'replace'", "mode.js");
    f.out.clearRetainingCapacity();
    rpc.serve(testing.allocator, &f.stream, line);
    try f.settleInputs();
    const Created = struct { result: proto.session.SessionResult };
    const created = try std.json.parseFromSliceLeaky(Created, a, f.out.written(), .{ .ignore_unknown_fields = true });
    const id = created.result.session.id;
    const page = try database.message.historyPage(&f.fixture.app.db, a, id.raw, 0, 10);
    try testing.expectEqualStrings("replaced", page.messages[0].user.content[0].text.text);
}

test "RPC lists, reads, and stops a background job, and hears its start and its end" {
    var f: TestFixture = undefined;
    try f.init();
    defer f.deinit();
    const host = f.fixture.extensions.host;
    f.fixture.app.engine.sinks.add(.{ .ctx = @ptrCast(&f.stream), .on_event = rpc.Rpc.onEvent });
    defer f.fixture.app.engine.sinks.remove(@ptrCast(&f.stream));

    try host.evalModule(
        \\import { start } from "yuke:internal/jobs";
        \\import { events } from "yuke:internal/kernel";
        \\globalThis.started = 0;
        \\globalThis.indexDigests = 0;
        \\events.on("engine.drained", (ev) => { if (ev.type === "index") indexDigests++; });
        \\start("echo hello; sleep 30", "01010101010101010101010101010101", { workspaceRoot: "/tmp" }).then(() => { started = 1; });
    , "rpc-job.js");
    try support.pumpUntilTrue(host, "globalThis.started === 1");
    // A job change moves no view, so the digest delivers no index change for it.
    try testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.indexDigests"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const job_id = host.jobs.list.items[0].id;
    f.stream.flushNotifications();
    try testing.expect(std.mem.indexOf(u8, f.out.written(), try std.fmt.allocPrint(a, "{{\"method\":\"job.changed\",\"params\":{{\"job\":{{\"id\":{d},\"session_id\":\"01010101010101010101010101010101\",\"command\":\"echo hello; sleep 30\",\"cwd\":\"/tmp\",\"state\":\"running\"", .{job_id})) != null);
    const listed = try std.fmt.allocPrint(a, "\"result\":{{\"jobs\":[{{\"id\":{d},", .{job_id});

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"list","method":"job.list","params":{"session_id":"01010101010101010101010101010101"}}
    );
    try testing.expect(std.mem.indexOf(u8, f.out.written(), try std.mem.concat(a, u8, &.{ "{\"id\":\"list\",", listed })) != null);
    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"other","method":"job.list","params":{"session_id":"02020202020202020202020202020202"}}
    );
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "{\"id\":\"other\",\"result\":{\"jobs\":[]}}") != null);
    // An explicit null stands for the optional parameter object.
    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"all","method":"job.list","params":null}
    );
    try testing.expect(std.mem.indexOf(u8, f.out.written(), try std.mem.concat(a, u8, &.{ "{\"id\":\"all\",", listed })) != null);

    // A running job has no output event, so poll its log under one failure deadline.
    const read_deadline = std.Io.Clock.Timestamp.fromNow(f.fixture.reactor.io(), .{ .raw = .fromSeconds(5), .clock = .awake });
    while (true) {
        rpc.serve(testing.allocator, &f.stream, try std.fmt.allocPrint(a, "{{\"id\":\"read\",\"method\":\"job.read\",\"params\":{{\"id\":{d},\"offset\":0,\"max_bytes\":1024}}}}", .{job_id}));
        if (std.mem.indexOf(u8, f.out.written(), "{\"id\":\"read\",\"result\":{\"start\":0,\"complete\":false,\"text\":\"hello\\n\",\"next\":6,\"size\":6}}") != null) break;
        if (read_deadline.durationFromNow(f.fixture.reactor.io()).raw.nanoseconds <= 0) return error.JobOutputDidNotArrive;
        try f.fixture.reactor.io().sleep(.fromMilliseconds(10), .awake);
    }
    rpc.serve(testing.allocator, &f.stream, try std.fmt.allocPrint(a, "{{\"id\":\"big\",\"method\":\"job.read\",\"params\":{{\"id\":{d},\"offset\":0,\"max_bytes\":262145}}}}", .{job_id}));
    try testing.expect(std.mem.endsWith(u8, f.out.written(), "{\"id\":\"big\",\"error\":{\"code\":-32602,\"message\":\"bad parameters\"}}\n"));
    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"gone","method":"job.stop","params":{"id":9}}
    );
    try testing.expect(std.mem.endsWith(u8, f.out.written(), "{\"id\":\"gone\",\"error\":{\"code\":-31029,\"message\":\"unknown job\"}}\n"));

    rpc.serve(testing.allocator, &f.stream, try std.fmt.allocPrint(a, "{{\"id\":\"stop\",\"method\":\"job.stop\",\"params\":{{\"id\":{d}}}}}", .{job_id}));
    try testing.expect(std.mem.indexOf(u8, f.out.written(), try std.fmt.allocPrint(a, "{{\"id\":\"stop\",\"result\":{{\"job\":{{\"id\":{d},", .{job_id})) != null);
    try host.evalModule("import { events } from \"yuke:internal/kernel\"; globalThis.ended = 0; events.on(\"jobs.changed\", (job) => { if (job.state === \"exited\" && job.stop_requested) ended = 1; });", "rpc-job-end.js");
    try support.pumpUntilTrue(host, "globalThis.ended === 1");
    f.stream.flushNotifications();
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\"state\":\"exited\",\"stop_requested\":true,\"signal\":15,") != null);
}

test "a job that ends by itself tells its session once as a protected input, and a stopped job tells nothing" {
    var f: TestFixture = undefined;
    try f.init();
    defer f.deinit();
    const host = f.fixture.extensions.host;
    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"c","method":"session.create","params":{"workspace_path":"/tmp/yuke-rpc-job-end","model":"test/model"}}
    );
    const Created = struct { result: struct { session: struct { id: []const u8 } } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const created = try std.json.parseFromSliceLeaky(Created, a, f.out.written(), .{ .ignore_unknown_fields = true });
    const id = created.result.session.id;
    const source = try std.fmt.allocPrintSentinel(a,
        \\import {{ start, stop }} from "yuke:internal/jobs";
        \\import {{ events }} from "yuke:internal/kernel";
        \\globalThis.ended = 0;
        \\events.on("jobs.changed", (job) => {{ if (job.state !== "running") ended++; }});
        \\start("seq 1 21; exit 2", "{s}", {{ workspaceRoot: "/tmp" }});
        \\start("true", "{s}", {{ workspaceRoot: "/tmp" }});
        \\start("sleep 30", "{s}", {{ workspaceRoot: "/tmp" }}).then((job) => stop(job.id));
    , .{ id, id, id }, 0);
    try host.evalModule(source, "rpc-job-end.js");
    try support.pumpUntilTrue(host, "globalThis.ended === 3");
    var raw: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, id);
    // The end wakes its session, so a run takes each end from the queue into the transcript.
    const deadline = std.Io.Clock.Timestamp.fromNow(f.fixture.reactor.io(), .{ .raw = .fromSeconds(5), .clock = .awake });
    while ((try database.input.list(&f.fixture.app.db, a, raw)).len != 0) {
        if (deadline.durationFromNow(f.fixture.reactor.io()).raw.nanoseconds <= 0) return error.JobEndNotTaken;
        try f.fixture.reactor.io().sleep(.fromMilliseconds(10), .awake);
    }
    var ends: [2]?[]const proto.content.ContentPart = .{ null, null };
    var count: usize = 0;
    for ((try database.message.historyPage(&f.fixture.app.db, a, raw, 0, 20)).messages) |message| if (message == .user) if (message.user.source) |s| if (s == .job_ended) {
        count += 1;
        ends[if (std.mem.eql(u8, s.job_ended.command, "true")) 1 else 0] = message.user.content;
    };
    try testing.expectEqual(@as(usize, 2), count);
    const seq = ends[0].?;
    try testing.expect(std.mem.startsWith(u8, seq[0].text.text, "[job-") and std.mem.endsWith(u8, seq[0].text.text, " exited 2. This message is not from the user.]\n"));
    // The body holds the log path and the last 20 lines.
    try testing.expect(std.mem.startsWith(u8, seq[1].text.text, "Log: /") and std.mem.endsWith(u8, seq[1].text.text, "\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21"));
    try testing.expect(std.mem.indexOf(u8, seq[1].text.text, "\n1\n") == null);
    try testing.expect(std.mem.endsWith(u8, ends[1].?[1].text.text, "\n[no output]"));
}

test "a removed session stops its running jobs" {
    var f: TestFixture = undefined;
    try f.init();
    defer f.deinit();
    const host = f.fixture.extensions.host;

    rpc.serve(testing.allocator, &f.stream,
        \\{"id":"c","method":"session.create","params":{"workspace_path":"/tmp/yuke-rpc-jobs","model":"test/model"}}
    );
    const Created = struct { result: struct { session: struct { id: []const u8 } } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const created = try std.json.parseFromSliceLeaky(Created, a, f.out.written(), .{ .ignore_unknown_fields = true });
    const id = created.result.session.id;

    const source = try std.fmt.allocPrintSentinel(a,
        \\import {{ start }} from "yuke:internal/jobs";
        \\import {{ events }} from "yuke:internal/kernel";
        \\globalThis.state = "";
        \\events.on("jobs.changed", (job) => {{ state = job.state; }});
        \\start("sleep 30", "{s}", {{ workspaceRoot: "/tmp" }});
        \\start("sleep 30", "{s}", {{ workspaceRoot: "/tmp" }});
    , .{ id, "01010101010101010101010101010101" }, 0);
    try host.evalModule(source, "rpc-remove-jobs.js");
    try support.pumpUntilTrue(host, "globalThis.state === \"running\"");

    const remove = try std.fmt.allocPrint(a,
        \\{{"id":"r","method":"session.remove","params":{{"session_id":"{s}"}}}}
    , .{id});
    rpc.serve(testing.allocator, &f.stream, remove);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "{\"id\":\"r\",\"result\":{}}") != null);
    try support.pumpUntilTrue(host, "globalThis.state === \"exited\"");
    // The job of another session keeps running. The table keeps start order.
    try testing.expectEqual(proto.job.JobState.running, host.jobs.list.items[1].state);
    try testing.expectEqual(proto.job.JobState.exited, host.jobs.list.items[0].state);
}
