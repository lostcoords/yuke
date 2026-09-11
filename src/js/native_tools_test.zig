const support = @import("test_support.zig");
const zio = @import("zio");
const host_mod = @import("host.zig");
const std = @import("std");
const Host = @import("host.zig").Host;
const tools_table = @import("tools.zig");

test "yuke:fs reads, writes and stats a real directory through promises" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "one\ntwo\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    // A real task needs a reactor, so this test runs on one instead of the testing I/O.
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/fsp.test.js");
    try support.pumpUntilIdle(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.done"));
}

test "a hook fault in one result does not stop later handlers" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/hook-fault.test.js");

    const call = host.calls.submitHook("input.before", "{}");
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"type\":\"block\",\"reason\":\"accepted\"}", call.text.?);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt(
        \\globalThis.faults.join(",") === "getter:getter,convert:convert" ? 1 : 0
    ));
    try support.dropCall(host, call);
}

test "the owner runs an async handler and answers its resolved value" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/run.test.js");

    // A synchronous callback violates the tool contract.
    {
        const call = host.calls.submit("sync", "{\"city\":\"Tokyo\"}", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("the tool execute function must return a Promise", call.text.?);
        try support.dropCall(host, call);
    }
    // A Promise settles through the job drain, so one pump is still enough.
    {
        const call = host.calls.submit("later", "{\"city\":\"Kyoto\"}", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expectEqualStrings("{\"got\":\"Kyoto\",\"async\":true}", call.text.?);
        try support.dropCall(host, call);
    }
    // A string passes through, because a text tool must not gain quotes.
    {
        const call = host.calls.submit("text", "{\"city\":\"Osaka\"}", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expectEqualStrings("just text", call.text.?);
        try support.dropCall(host, call);
    }
    {
        const call = host.calls.submit("nothing", "{\"city\":\"Nara\"}", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expectEqualStrings("", call.text.?);
        try support.dropCall(host, call);
    }
    // Every record swept, so the host holds nothing after the calls.
    try std.testing.expectEqual(@as(usize, 0), host.calls.live.items.len);
}

test "a failed handler answers the model with an error it can read" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/fail.test.js");

    const cases = [_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "throws", .want = "it broke" },
        .{ .name = "cycles", .want = "the tool answered a value that is not JSON" },
    };
    for (cases) |case| {
        const call = host.calls.submit(case.name, "{\"city\":\"Tokyo\"}", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings(case.want, call.text.?);
        try support.dropCall(host, call);
    }

    // A name that no tool owns, and arguments that are not JSON, are engine input, not a crash.
    {
        const call = host.calls.submit("absent", "{}", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("the tool is not registered", call.text.?);
        try support.dropCall(host, call);
    }
    {
        const call = host.calls.submit("throws", "not json", "");
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("the arguments are not valid JSON", call.text.?);
        try support.dropCall(host, call);
    }
    // A pending exception from any of those must not change the next call.
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("3 + 4"));
}

test "a handler that awaits a primitive answers when the task finishes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "from disk" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/await.test.js");

    // The handler holds a task, not the owner, so the call settles only after the read finishes.
    const call = host.calls.submit("read_note", "{\"path\":\"note.txt\"}", "");
    try host.pump();
    try std.testing.expectEqual(tools_table.Call.State.running, call.state);

    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"text\":\"from disk\"}", call.text.?);
    try support.dropCall(host, call);
}

test "a handler reads the signal after the turn leaves" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/signal.test.js");

    const call = host.calls.submit("watch", "{\"city\":\"Tokyo\"}", "");
    try host.pump();
    try support.expectString(host, "seen", "live"); // the handler read the flag at its start
    _ = try host.evalInt("globalThis.check(), 0");
    try support.expectString(host, "seen", "live");

    // The turn leaves, so the next pass marks the signal before any job runs, then sweeps the record.
    host.ctx.freeValue(try host.ctx.eval("globalThis.release()", "release.js", .{})); // the job stays queued
    call.finish();
    try host.pump();
    try std.testing.expectEqual(@as(usize, 0), host.calls.live.items.len);
    try support.expectString(host, "seen", "aborted");
    _ = try host.evalInt("globalThis.check(), 0");
    try support.expectString(host, "seen", "aborted");
}

test "closing the host answers a call nobody would settle" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/hang.test.js");

    const call = host.calls.submit("hangs", "{\"city\":\"Tokyo\"}", "");
    try host.pump();
    try std.testing.expectEqual(tools_table.Call.State.running, call.state);

    // A turn task waits on this event. A close that leaves it unset would hang the shutdown.
    try host.close();
    try std.testing.expectEqual(tools_table.Call.State.settled, call.state);
    try std.testing.expect(call.is_error);
    try std.testing.expect(call.done.isSet());
}

test "defineTool registers a tool and states its raw schema" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/tool.test.js");

    try std.testing.expectEqual(@as(usize, 1), host.tools.entries.items.len);
    const tool = host.tools.entries.items[host.tools.find("get_weather").?].decl;
    try std.testing.expectEqualStrings("Report the weather of one city.", tool.description);
    // The schema reaches the provider unchanged, so an enum and a shorter `required` survive.
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"description\":\"The city to report.\"}," ++
            "\"unit\":{\"type\":\"string\",\"enum\":[\"celsius\",\"fahrenheit\"],\"description\":\"The unit of temperature.\"}}," ++
            "\"required\":[\"city\"]}",
        tool.input_schema,
    );
    try std.testing.expectEqualStrings("get_weather", host.tools.entries.items[0].decl.name);
}

test "defineTool refuses every definition a provider would reject" {
    const host = support.createHost();
    defer support.destroyHost(host);

    // Each case must throw, because `index.js` is user input that has to fail loudly at boot.
    try support.eval(host, "tests/native_tools/refuse.test.js");

    // Only the one valid registration reached the table.
    try std.testing.expectEqual(@as(usize, 1), host.tools.entries.items.len);
}

test "a tool registers after boot and keeps the advertised order stable" {
    const host = support.createHost();
    defer support.destroyHost(host);

    // Registration order is not the advertised order, so a load order change cannot move the prefix.
    try support.eval(host, "tests/native_tools/boot-6.test.js");

    // A plugin may add a tool after boot, and it lands in the same sorted position.
    try support.eval(host, "tests/native_tools/late.test.js");

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(std.testing.allocator);
    for (host.tools.entries.items) |entry| {
        const d = entry.decl;
        if (names.items.len != 0) try names.append(std.testing.allocator, ',');
        try names.appendSlice(std.testing.allocator, d.name);
    }
    try std.testing.expectEqualStrings("alpha,bravo,mike,zulu", names.items);
}

test "baked tools preserve file edits, bounded reads, views, and command output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\ntwo\n" });
    const long_line = try std.testing.allocator.alloc(u8, 8001);
    defer std.testing.allocator.free(long_line);
    @memset(long_line, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = long_line });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "/tmp");
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/builtins-test.test.js");

    {
        const call = host.calls.submit("read", "{\"path\":\"a.txt\",\"start\":2,\"end\":3}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expectEqualStrings("2: two\n3: two", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("read", "{\"path\":\"long.txt\"}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.endsWith(u8, call.text.?, "[The tool cut 1 line(s) at 8000 bytes.]"));
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("read", "{\"path\":\"missing.txt\"}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("read: the path does not exist", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("read", "{\"path\":1}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings("read: the argument path must be a string", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("edit", "{\"path\":\"a.txt\",\"old_string\":\"two\",\"new_string\":\"TWO\"}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "more than one") != null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("edit", "{\"path\":\"a.txt\",\"old_string\":\"two\",\"new_string\":\"TWO\",\"replace_all\":true}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "replaced 2") != null);
        try std.testing.expect(call.view_json != null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("write", "{\"path\":\"new.txt\",\"content\":\"fresh\\n\"}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "wrote 6 bytes") != null);
        try std.testing.expect(call.view_json != null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("write", "{\"path\":\"a.txt\",\"content\":\"one\\nTWO\\nTWO\\n\"}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(call.view_json == null);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("exec", "{\"command\":\"echo out; echo err 1>&2; exit 3\"}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expectEqualStrings("out\n[stderr]\nerr\n[exit code: 3]", call.text.?);
        call.finish();
        try host.pump();
    }
    {
        const call = host.calls.submit("exec", "{\"command\":\"sleep 30\",\"timeout_ms\":300}", root);
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(!call.is_error);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "[The command passed its 300 ms timeout.") != null);
        call.finish();
        try host.pump();
    }
}

test "a user edit tool overrides the baked edit tool" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/index.test.js");
    try support.eval(host, "tests/native_tools/builtins.test.js");

    const call = host.calls.submit("edit", "{}", "");
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("user edit", call.text.?);
    call.finish();
    try host.pump();
}

test "exec call abort ends its process group and preserves unrelated work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);
    try host.evalModule("import \"yuke:builtins\";", "builtins.js");

    const canceled = host.calls.submit("exec",
        \\{"command":"sleep 30 & child=$!; trap 'wait \"$child\"; exit 0' TERM; echo $$ $child > started; wait \"$child\""}
    , root);
    const survivor = host.calls.submit("exec", "{\"command\":\"sleep 1; echo survived\"}", root);
    try host.pump();
    const pids = try waitExecPids(host, tmp.dir);
    try std.testing.expect(processExists(pids[0]));
    try std.testing.expect(processExists(pids[1]));

    const started: std.Io.Timestamp = .now(host.io, .awake);
    canceled.finish();
    try host.pump();
    try std.testing.expect(started.durationTo(.now(host.io, .awake)).toMilliseconds() < 500);
    while (host.ops.live.items.len != 0) {
        if (started.durationTo(.now(host.io, .awake)).toMilliseconds() > 8000) return error.ExecAbortDidNotStop;
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
        host.wake.reset();
        try host.pump();
    }
    try std.testing.expect(!processExists(pids[0]));
    try std.testing.expect(!processExists(pids[1]));
    try std.testing.expect(survivor.state == .settled);
    try std.testing.expect(!survivor.is_error);
    try std.testing.expect(std.mem.indexOf(u8, survivor.text.?, "survived") != null);
    try support.dropCall(host, survivor);
}

test "exec rejects forged and retained signals and aborts before process creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/exec-signal.test.js");
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.refusals"));
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    const call = host.calls.submit("probe", "{}", root);
    try host.pump();
    try std.testing.expectEqual(@as(usize, 2), host.ops.live.items.len);
    call.finish();
    try host.pump();
    try support.pumpUntilIdle(host);
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.prelaunch"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.retained.aborted"));
    try host.evalModule("globalThis.retained.aborted = false; globalThis.resume();", "late-exec.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.late"));
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "forbidden", .{}));
}

test "exec completion detaches before call abort and host close rejects late exec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/exec-complete.test.js");
    const call = host.calls.submit("probe", "{}", "/tmp");
    try host.pump();
    try support.pumpUntilIdle(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished"));
    try std.testing.expect(call.state == .running);
    try support.dropCall(host, call);
    const race = host.calls.submit("probe", "{}", root);
    try host.pump();
    const ready: std.Io.Timestamp = .now(host.io, .awake);
    while (!host.ops.anyDone()) {
        if (ready.durationTo(.now(host.io, .awake)).toMilliseconds() > 5000) return error.ExecDidNotFinish;
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        host.wake.reset();
    }
    try support.dropCall(host, race);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try support.eval(host, "tests/native_tools/exec-close.test.js");
    const pids = try waitExecPids(host, tmp.dir);
    const started: std.Io.Timestamp = .now(host.io, .awake);
    try host.close();
    try std.testing.expect(started.durationTo(.now(host.io, .awake)).toMilliseconds() < 8000);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expect(!processExists(pids[0]));
    try std.testing.expect(!processExists(pids[1]));
    const closed = try host.ctx.eval("globalThis.closed", "closed.js", .{});
    defer host.ctx.freeValue(closed);
    try std.testing.expectEqual(@as(i32, 1), try host.ctx.toInt32(closed));
}

test "session cancel reaches the builtin exec process group" {
    const commands = @import("../engine/commands.zig");
    const turn = @import("../engine/turn.zig");
    const provider = @import("../provider/provider.zig");
    var f: @import("extensions.zig").Fixture = undefined;
    try f.init("", "import \"yuke:kernel\"; import \"yuke:ext\";");
    defer f.deinit();
    const host = f.extensions.host;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var models = try provider.config.loadBytes(f.gpa.allocator(),
        \\{"version":1,"providers":[{"id":"test-exec","base_url":"https://test.invalid",
        \\"protocol":"anthropic_messages","auth":{"api_key":{"header":"x_api_key","source":{"literal":"test-key"}}},"models":[{"id":"model","upstream_id":"model"}]}]}
    );
    _ = try f.app.store.installLocal(&models);
    const model = f.app.store.merged.resolveModel("test-exec/model").?;
    try std.testing.expect(model.provider.availability == .ready);
    const args = try std.json.Stringify.valueAlloc(a, .{
        .command = "sleep 30 & child=$!; trap 'wait \"$child\"; exit 0' TERM; echo $$ $child > started; wait \"$child\"",
    }, .{});
    const delta = try std.json.Stringify.valueAlloc(a, .{
        .type = "content_block_delta",
        .index = 0,
        .delta = .{ .type = "input_json_delta", .partial_json = args },
    }, .{});
    f.canned.bytes = try std.mem.concat(a, u8, &.{
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-exec\",\"name\":\"exec\",\"input\":{}}}\n\n",
        "data: ",
        delta,
        "\n\n",
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":8}}\n\n",
        "data: {\"type\":\"message_stop\"}\n\n",
    });
    const created = try commands.sessionCreate(&f.app.engine, a, .{ .workspace_path = host.cwd, .model = "test-exec/model" });
    var launch: ?turn.Launch = null;
    _ = try commands.sessionSendInputForRpc(&f.app.engine, a, .{
        .session_id = created.session.id,
        .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "Run the command." } }} } },
    }, &launch, null);
    turn.Launch.release(&launch, &f.app.engine);
    const pids = try waitExecPids(host, f.tmp.dir);
    const canceled = try commands.sessionCancelRun(&f.app.engine, a, .{ .session_id = created.session.id });
    try std.testing.expect(canceled.canceled_run != null);
    const started: std.Io.Timestamp = .now(host.io, .awake);
    while (host.calls.live.items.len != 0 or host.ops.live.items.len != 0) {
        if (started.durationTo(.now(host.io, .awake)).toMilliseconds() > 8000) return error.ExecAbortDidNotStop;
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
        host.wake.reset();
        try host.pump();
    }
    try std.testing.expect(!processExists(pids[0]));
    try std.testing.expect(!processExists(pids[1]));
}

test "yuke:exec runs commands on tasks and reports each outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker.txt", .data = "found\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    // A command needs a real reactor, because it runs on its own task.
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/exec.test.js");
    try support.pumpUntilIdle(host);
    try support.expectString(host, "result", "ok");
}

test "yuke:exec ends a command that passes its deadline" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "/tmp");
    defer support.destroyHost(host);

    // The deadline must stop the command and name the outcome. A failed kill would wait 30 seconds.
    const started: std.Io.Timestamp = .now(rt.io(), .awake);
    try support.eval(host, "tests/native_tools/deadline.test.js");
    // The command holds a task, not the owner: the promise is pending and the owner still runs.
    try std.testing.expectEqual(@as(usize, 1), host.ops.live.items.len);
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("3 + 4"));

    try support.pumpUntilIdle(host);
    try support.expectString(host, "result", "ok");
    try std.testing.expect(started.durationTo(.now(rt.io(), .awake)).toNanoseconds() < 20 * std.time.ns_per_s);
}

test "yuke:diff describes a change, an equal pair, and a new file" {
    // The compare stays on the owner, so this needs no reactor.
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/diff.test.js");
    try host.drainJobs();
    try support.expectString(host, "result", "ok");
}

test "a primitive stays pending until the owner lets its task run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);

    try support.eval(host, "tests/native_tools/pend.test.js");

    // The owner has not waited, so the task has not run and the promise is still pending.
    try host.drainJobs();
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.settled"));
    try std.testing.expectEqual(@as(usize, 1), host.ops.live.items.len);

    try support.pumpUntilIdle(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.settled"));
}

test "a throwing await handler faults once and leaves no pending exception" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), root);
    defer support.destroyHost(host);

    // A resolver that throws must not leave an exception for the next owner turn.
    try support.eval(host, "tests/native_tools/throwy.test.js");

    var rounds: u32 = 0;
    while (host.ops.live.items.len != 0) : (rounds += 1) {
        if (rounds == 64) return error.PrimitiveNeverSettled;
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }) catch {};
        host.wake.reset();
        // The throw happens in a job, so `pump` reports it through the job drain, not the settle.
        host.pump() catch |err| try std.testing.expectEqual(host_mod.Error.JavaScriptFault, err);
    }
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ran"));
    // The next call must see a clean context, so a later read still works.
    try host.evalModule("globalThis.after = 7;", "after.js");
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("globalThis.after"));
}

test "run cleanup stops signaled exec without another owner pump" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const host = support.createHostWith(runtime.io(), root);
    defer support.destroyHost(host);
    try host.evalModule("import \"yuke:builtins\";", "builtins.js");
    var work: @import("../session/work.zig") = .{};
    const call = host.calls.submit("exec",
        \\{"command":"sleep 30 & child=$!; trap 'wait \"$child\"; exit 0' TERM; echo $$ $child > started; wait \"$child\""}
    , root);
    call.work = &work;
    try host.pump();
    const pids = try waitExecPids(host, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), work.pending);
    call.finish();
    work.drain(runtime.io());
    try std.testing.expectEqual(@as(usize, 0), work.pending);
    try std.testing.expect(!processExists(pids[0]));
    try std.testing.expect(!processExists(pids[1]));
    try host.pump();
}

test "tool site attributes a question and call completion cancels it" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/ask.test.js");
    const call = host.calls.submit("ask", "{}", "/work");
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 4, .part_id = 2 };
    try host.pump();
    const question = host.interactions.takeNext().?;
    try std.testing.expectEqualSlices(u8, &([_]u8{1} ** 16), &question.session_id.?.raw);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.site"));
    call.finish();
    try host.pump();
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
}

test "a hidden cancellation watch is never listed and no peer can answer it" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/native_tools/wait.test.js");
    const call = host.calls.submit("wait", "{}", "/work");
    try host.pump();
    try std.testing.expect(host.interactions.takeNext() == null);
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{ .interaction_id = 7, .response = .{ .confirm = .{ .value = true } } }));
    try host.pump();
    try support.expectString(host, "seen", "pending");
    call.finish();
    try host.pump();
    try support.expectString(host, "seen", "canceled");
}

fn waitExecPids(host: *Host, dir: std.Io.Dir) ![2]std.posix.pid_t {
    const started: std.Io.Timestamp = .now(host.io, .awake);
    while (started.durationTo(.now(host.io, .awake)).toMilliseconds() < 5000) {
        const text = dir.readFileAlloc(std.testing.io, "started", std.testing.allocator, .limited(128)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (text) |bytes| {
            defer std.testing.allocator.free(bytes);
            if (std.mem.endsWith(u8, bytes, "\n")) {
                var words = std.mem.tokenizeAny(u8, bytes, " \n");
                return .{
                    try std.fmt.parseInt(std.posix.pid_t, words.next().?, 10),
                    try std.fmt.parseInt(std.posix.pid_t, words.next().?, 10),
                };
            }
        }
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        host.wake.reset();
        try host.pump();
    }
    return error.ExecDidNotStart;
}

fn processExists(pid: std.posix.pid_t) bool {
    std.debug.assert(pid > 0);
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}
