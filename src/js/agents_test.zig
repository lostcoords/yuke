//! Setup tests replace the client boundary and keep the real promise coordinator.

const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;
const proto = @import("proto");

test "setup coalesces both slots and continues one atomic spawn per caller" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/coalesce.test.js");
    try support.expectString(host, "result", "ok");
}

test "required slots headless setup and user cancellation have no child side effects" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/refusals.test.js");
    try support.expectString(host, "result", "ok");
}

test "setup preserves concurrent slot choices and propagates a failed save" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/save-conflict.test.js");
    try support.expectString(host, "result", "ok");
}

test "model repair changes a child without a new run or an implicit slot edit" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/repair.test.js");
    try support.expectString(host, "result", "ok");
}

test "tool cancellation removes the setup question and rejects a late answer" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/tool.test.js");
    const call = host.calls.submit("spawn-test", "{}", "/work");
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    try host.pump();
    const question = host.interactions.takeNext().?;
    try std.testing.expect(question.request == .confirm);
    try std.testing.expectEqual(proto.ids.SessionId.bytes([_]u8{1} ** 16), question.session_id.?);
    try support.dropCall(host, call);
    try support.expectString(host, "result", "tool_cancelled");
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.creates"));
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{ .interaction_id = question.interaction_id, .response = .{ .confirm = .{ .value = true } } }));
}

test "a canceled tool cannot spawn after its pending config save succeeds" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/late-save.test.js");
    const call = host.calls.submit("spawn-test", "{}", "/work");
    try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("typeof finishSave === 'function' ? 1 : 0"));
    try support.dropCall(host, call);
    try support.expectString(host, "result", "tool_cancelled");
    try host.evalModule("finishSave();", "save.js");
    try support.expectString(host, "result", "tool_cancelled");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("stats.saves"));
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.creates"));
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
}

test "a live setup follower resumes after the lead tool is canceled" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/follower.test.js");
    const lead = host.calls.submit("one", "{}", "/work");
    try host.pump();
    const old_question = host.interactions.takeNext().?;
    const follower = host.calls.submit("two", "{}", "/work");
    defer follower.finish();
    try host.pump();
    try std.testing.expect(host.interactions.takeNext() == null);
    lead.finish();
    try host.pump();
    const question = host.interactions.takeNext().?;
    try std.testing.expect(question.interaction_id != old_question.interaction_id);
    try host.interactions.respond(.{ .interaction_id = question.interaction_id, .response = .{ .confirm = .{ .value = true } } });
    // One provider needs no pick, and a slot names no level, so the model is the only choice.
    try host.pump();
    const pick = host.interactions.takeNext().?;
    try std.testing.expect(pick.request == .select);
    try host.interactions.respond(.{ .interaction_id = pick.interaction_id, .response = .{ .select = .{ .value = pick.request.select.options[0] } } });
    try host.pump();
    const both = host.interactions.takeNext().?;
    try host.interactions.respond(.{ .interaction_id = both.interaction_id, .response = .{ .confirm = .{ .value = true } } });
    try host.pump();
    try host.evalModule("result = one + '/' + two + '/' + stats.creates;", "result.js");
    try support.expectString(host, "result", "tool_cancelled/spawned/1");
}

test "cancellation watch refusal is an operating error and does not retry setup" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/invalid-signal.test.js");
    try support.expectString(host, "result", "runtime_failed");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.saves + stats.creates"));
}

test "first use connects an API key provider with a secret prompt" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/api-key.test.js");
    try support.expectString(host, "result", "ok");
}

test "shared credential repair handles a login result before the start response" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/shared-login.test.js");
    try support.expectString(host, "result", "ok");
}

test "tool cancellation stops its pending device login without child admission" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/cancel-login.test.js");
    const call = host.calls.submit("spawn-test", "{}", "/work");
    try host.pump();
    try std.testing.expect(host.interactions.live.items.len > 0);
    try support.dropCall(host, call);
    try support.expectString(host, "result", "tool_cancelled");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("canceledLogin === 'login' ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.creates + stats.saves"));
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
}

const ToolAnswer = struct { text: []u8, is_error: bool };

fn invokeAgent(host: *Host, name: []const u8, args: []const u8) !ToolAnswer {
    const call = host.calls.submit(name, args, "/work");
    defer call.finish();
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    for (0..4) |_| try host.pump();
    try std.testing.expectEqual(@import("tools.zig").Call.State.settled, call.state);
    return .{ .text = try std.testing.allocator.dupe(u8, call.text orelse ""), .is_error = call.is_error };
}

const tool_fixture =
    \\import { plugins } from "yuke:ext";
    \\import { agentToolsPlugin } from "yuke:agent-tools";
    \\plugins.use(agentToolsPlugin);
    \\map.config.models = { small: { model: "p/family/model" }, medium: { model: "p/family/model" } };
    \\globalThis.child = { session: { id: "02".repeat(16), name: "one", root: "/work", model: "p/family/model", origin: { type: "child", site: { session_id: "01".repeat(16), message_id: 1, part_id: 0 } } }, activity: { state: { type: "idle" }, queued: 0 }, last_run: { type: "turn" } };
    \\client.sessionList = async (params) => { return { items: params.population.parent_id === "01".repeat(16) ? [child] : [], next_cursor: null, total: 1 }; };
    \\client.sessionGet = async (id, name) => name === child.session.name || id === child.session.id ? child : { session: { id, title: "Main conversation", root: "/work", model: "parent/large", origin: { type: "root" } }, activity: { state: { type: "idle" }, queued: 0 } };
    \\client.sessionSendInput = async (id, text, site) => { if (id !== child.session.id || site.message_id !== 2) throw new Error("instruction"); return text === "go" ? { type: "started", input_id: 3, run_id: 1 } : { type: "queued", reason: "session_busy", input_id: 2 }; };
    \\client.sessionCancelRun = async (id, clear) => { if (id !== child.session.id || !clear) throw new Error("stop scope"); return { canceled_run: null, cleared_inputs: [2] }; };
;

test "nested child spawn delegates depth and child identity to native" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/nested.test.js");
    try support.expectString(host, "result", "ok");
}

test "agent tools expose explicit slots and truthful reusable child receipts" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    for (host.tools.entries.items) |entry| if (std.mem.eql(u8, entry.decl.name, "spawn_agent")) {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, entry.decl.input_schema, .{});
        defer parsed.deinit();
        const schema = parsed.value.object;
        try std.testing.expect(!schema.get("additionalProperties").?.bool);
        try std.testing.expectEqualStrings("model", schema.get("required").?.array.items[2].string);
        try std.testing.expectEqual(@as(usize, 2), schema.get("properties").?.object.get("model").?.object.get("enum").?.array.items.len);
    };
    for ([_][]const u8{ "{\"name\":\"one\",\"message\":\"task\"}", "{\"name\":\"one\",\"message\":\"task\",\"model\":null}", "{\"name\":\"one\",\"message\":\"task\",\"model\":\"p/model\"}" }) |args| {
        const answer = try invokeAgent(host, "spawn_agent", args);
        defer std.testing.allocator.free(answer.text);
        try std.testing.expect(answer.is_error);
    }
    const spawn = try invokeAgent(host, "spawn_agent", "{\"name\":\"one\",\"message\":\"task\",\"model\":\"small\"}");
    defer std.testing.allocator.free(spawn.text);
    try std.testing.expect(!spawn.is_error);
    const receipt = try std.json.parseFromSlice(struct { name: []const u8, session_id: []const u8, model: []const u8, state: []const u8, note: []const u8 }, std.testing.allocator, spawn.text, .{});
    defer receipt.deinit();
    try std.testing.expectEqualStrings("queued", receipt.value.state);
    try std.testing.expect(receipt.value.note.len > 0);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("created.child.slot === 'small' && stats.creates === 1 ? 1 : 0"));
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "send_agent_input", "{\"child\":\"one\",\"message\":\"more\"}", "{\"state\":\"queued\"}" },
        .{ "send_agent_input", "{\"child\":\"one\",\"message\":\"go\"}", "{\"state\":\"started\"}" },
        .{ "stop_agent", "{\"child\":\"one\"}", "cleared_inputs" },
        .{ "list_agents", "{}", "\"name\":\"one\"" },
    };
    for (cases) |case| {
        const answer = try invokeAgent(host, case[0], case[1]);
        defer std.testing.allocator.free(answer.text);
        try std.testing.expect(!answer.is_error);
        try std.testing.expect(std.mem.indexOf(u8, answer.text, case[2]) != null);
    }
    for (host.tools.entries.items) |entry| try std.testing.expect(!std.mem.eql(u8, entry.decl.name, "read_agent"));
    try host.evalModule("child.session.origin.site.session_id = 'other';", "foreign.js");
    const foreign = try invokeAgent(host, "stop_agent", "{\"child\":\"02020202020202020202020202020202\"}");
    defer std.testing.allocator.free(foreign.text);
    try std.testing.expect(foreign.is_error);
}

test "report previews fold independently of their stored text and queue clear preserves reports" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/report-ui.test.js");
    try support.expectString(host, "result", "ok");
}

test "agent picker opens children stops one or all and retains focused interrupt scope" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try support.eval(host, "tests/agents/agent-picker.test.js");
    try support.expectString(host, "result", "ok");
}

test "TUI tool questions show their owner and device login closes on completion" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/owner-question.test.js");
    const call = host.calls.submit("question", "{}", "/work");
    defer call.finish();
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].opts.title.includes('01010101') ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.length === 2 ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.map(answer => root.overlays[0].content.list.format(answer)).join('|') === 'Configure models|Later' ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.body.includes('/agent-models.') ? 1 : 0"));
    try host.evalModule("root.overlays[0].content.accept();", "answer.js");
    try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays.length"));
    try host.evalModule("finishLogin({ type: 'succeeded' });", "finish.js");
    try support.expectString(host, "result", "succeeded");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("root.overlays.length"));
}

test "the top-level session picker excludes child sessions" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/finder-mocks.test.js");
    try support.eval(host, "tests/agents/finder.test.js");
    for (0..4) |_| try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays.length"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.length"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source[0].id === 'parent' ? 1 : 0"));
}

test "a user tool can replace a stock agent tool without a boot failure" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/custom-agent.test.js");
    try host.evalModule(tool_fixture, "tools.js");
    const result = try invokeAgent(host, "spawn_agent", "{}");
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("custom agent", result.text);
}

test "stop all distinguishes changed idle and failed children" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/stop-all.test.js");
    try support.expectString(host, "result", "ok");
}

test "JavaScript leaves child prompt composition to native admission" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/child-prompt.test.js");
    try support.expectString(host, "result", "ok");
}

test "setup cancellation rows are neutral and errors remain visible" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/cancellation-rows.test.js");
    try support.expectString(host, "result", "ok");
}

test "explicit model edits skip onboarding and change only the selected slot" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/agents/fixture.js");
    try support.eval(host, "tests/agents/edit-slot.test.js");
    try support.expectString(host, "result", "ok");
}

const tree_fixture =
    \\import { client } from "yuke:client";
    \\globalThis.nodes = {
    \\  root: { session: { id: "root", name: "main", origin: { type: "root" } }, activity: { state: { type: "idle" }, queued: 0 } },
    \\  a: { session: { id: "a", name: "a", origin: { type: "child", site: { session_id: "root" } } }, activity: { state: { type: "idle" }, queued: 0 } },
    \\  b: { session: { id: "b", name: "b", origin: { type: "child", site: { session_id: "a" } } }, activity: { state: { type: "idle" }, queued: 0 } },
    \\  sibling: { session: { id: "sibling", name: "sibling", origin: { type: "child", site: { session_id: "root" } } }, activity: { state: { type: "idle" }, queued: 0 } },
    \\};
    \\client.sessionGet = async (id) => nodes[id];
    \\client.sessionList = async ({ population }) => ({ items: Object.values(nodes).filter((x) => x.session.origin.type === "child" && x.session.origin.site.session_id === population.parent_id), total: 0 });
    \\globalThis.result = "pending";
;

test "agent rows resolve the real root and include siblings and descendants" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(tree_fixture, "tree-fixture.js");
    try support.eval(host, "tests/agents/tree.test.js");
    try support.expectString(host, "result", "root:0,a:1,b:2,sibling:1");
}

test "agent rows reject cyclic ancestry" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(tree_fixture, "tree-fixture.js");
    try support.eval(host, "tests/agents/cycle.test.js");
    try support.expectString(host, "result", "The session ancestry contains a cycle.");
}
