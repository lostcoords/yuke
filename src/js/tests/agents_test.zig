//! Agent tests replace the client boundary and keep the real promise coordinator.

const support = @import("support.zig");
const std = @import("std");
const Host = @import("../host.zig").Host;

const root_id = "01010101010101010101010101010101";
const child_id = "02020202020202020202020202020202";

test "child pages return a complete list or refuse" {
    try support.run("agents/pages.test.js");
}

const ToolAnswer = struct { text: []u8, is_error: bool };

fn invokeAgent(host: *Host, name: []const u8, args: []const u8) !ToolAnswer {
    const call = host.calls.submit(name, args, "/work");
    defer call.finish();
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    for (0..4) |_| try host.pump();
    try std.testing.expectEqual(@import("../tools.zig").Call.State.settled, call.state);
    return .{ .text = try std.testing.allocator.dupe(u8, call.text orelse ""), .is_error = call.is_error };
}

fn answerHook(host: *Host, point: []const u8, payload: []const u8) ![]u8 {
    const call = host.calls.submitHook(point, payload);
    defer call.finish();
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    return std.testing.allocator.dupe(u8, call.text.?);
}

fn hasTool(host: *Host, name: []const u8) bool {
    for (host.tools.entries.items) |entry| if (std.mem.eql(u8, entry.decl.name, name)) return true;
    return false;
}

const tool_fixture =
    \\import { plugins } from "yuke:ext";
    \\import { agents } from "yuke:agents";
    \\plugins.use(agents({ default: "small", maxRounds: 7, catalog: { small: { description: "Narrow research.", model: "p/family/model" }, review: { description: "Read-only review.", prompt: "Review only. Do not edit.", tools: ["read", "exec"] } } }));
    \\globalThis.child = { session: { id: "02".repeat(16), name: "small", root: "/work", model: "p/family/model", origin: { type: "child", site: { session_id: "01".repeat(16), message_id: 1, part_id: 0 } } }, activity: { state: { type: "idle" }, queued: 0 }, last_run: { type: "turn" } };
    \\client.sessionList = async (params) => { return { items: params.population.parent_id === "01".repeat(16) ? [child] : [], next_cursor: null, total: 1 }; };
    \\client.sessionGet = async (id) => id === child.session.id ? child : { session: { id, title: "Main conversation", root: "/work", model: "parent/large", origin: { type: "root" } }, activity: { state: { type: "idle" }, queued: 0 } };
    \\client.sessionSendInput = async (id, content, site) => { if (id !== child.session.id || site.message_id !== 2) throw new Error("instruction"); return content[0].text === "go" ? { type: "started", input_id: 3, run_id: 1 } : { type: "queued", reason: "session_busy", input_id: 2 }; };
    \\client.sessionCancelRun = async (id, clear) => { if (id !== child.session.id || !clear) throw new Error("stop scope"); return { canceled_run: null, cleared_inputs: [2] }; };
;

test "the catalog is validated at boot and an absent plugin declares no agent tool" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try support.eval(host, "agents/catalog.test.js");
    try support.expectString(host, "result", "ok");
    for ([_][]const u8{ "spawn_agent", "send_agent_input", "stop_agent", "list_agents" }) |name| try std.testing.expect(!hasTool(host, name));
}

test "agent tools list the catalog, inherit the parent model, and address a child by id" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try std.testing.expect(!hasTool(host, "list_agents"));
    var seen = false;
    for (host.tools.entries.items) |entry| if (std.mem.eql(u8, entry.decl.name, "spawn_agent")) {
        seen = true;
        try std.testing.expect(std.mem.indexOf(u8, entry.decl.description, "- `small`: Narrow research.") != null);
        try std.testing.expect(std.mem.indexOf(u8, entry.decl.description, "Do not spawn a child unless the user asks") != null);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, entry.decl.input_schema, .{});
        defer parsed.deinit();
        const schema = parsed.value.object;
        try std.testing.expect(!schema.get("additionalProperties").?.bool);
        try std.testing.expectEqual(@as(usize, 1), schema.get("required").?.array.items.len);
        try std.testing.expectEqualStrings("message", schema.get("required").?.array.items[0].string);
        try std.testing.expectEqual(@as(usize, 2), schema.get("properties").?.object.get("agent").?.object.get("enum").?.array.items.len);
    };
    try std.testing.expect(seen);
    for ([_][]const u8{ "{}", "{\"message\":\"task\",\"agent\":\"ghost\"}", "{\"message\":\"task\",\"name\":\"one\"}", "{\"message\":\"\"}" }) |args| {
        const answer = try invokeAgent(host, "spawn_agent", args);
        defer std.testing.allocator.free(answer.text);
        try std.testing.expect(answer.is_error);
    }
    // A call with no live parent site is refused before any create.
    const orphan = host.calls.submit("spawn_agent", "{\"message\":\"task\"}", "/work");
    for (0..4) |_| try host.pump();
    try std.testing.expect(orphan.is_error);
    orphan.finish();
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.creates"));
    const Receipt = struct { session_id: []const u8, agent: []const u8, model: []const u8, state: []const u8 };
    const spawn = try invokeAgent(host, "spawn_agent", "{\"message\":\"task\"}");
    defer std.testing.allocator.free(spawn.text);
    try std.testing.expect(!spawn.is_error);
    const receipt = try std.json.parseFromSlice(Receipt, std.testing.allocator, spawn.text, .{});
    defer receipt.deinit();
    try std.testing.expectEqualStrings("small", receipt.value.agent);
    try std.testing.expectEqualStrings("p/family/model", receipt.value.model);
    try std.testing.expectEqualStrings("queued", receipt.value.state);
    try std.testing.expectEqualStrings(child_id, receipt.value.session_id);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("created.child.name === 'small' && created.child.site.session_id === '01'.repeat(16) && created.child.site.message_id === 2 && created.child.site.part_id === 0 && created.model === 'p/family/model' && created.reasoning === undefined && created.max_rounds === 7 && Object.keys(created.child).length === 2 ? 1 : 0"));
    const inherited = try invokeAgent(host, "spawn_agent", "{\"message\":\"task\",\"agent\":\"review\"}");
    defer std.testing.allocator.free(inherited.text);
    try std.testing.expect(!inherited.is_error);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("created.child.name === 'review' && created.model === 'parent/large' && stats.creates === 2 ? 1 : 0"));
    const by_name = try invokeAgent(host, "send_agent_input", "{\"child\":\"small\",\"message\":\"more\"}");
    defer std.testing.allocator.free(by_name.text);
    try std.testing.expect(by_name.is_error);
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "send_agent_input", "{\"child\":\"" ++ child_id ++ "\",\"message\":\"more\"}", "{\"state\":\"queued\"}" },
        .{ "send_agent_input", "{\"child\":\"" ++ child_id ++ "\",\"message\":\"go\"}", "{\"state\":\"started\"}" },
        .{ "stop_agent", "{\"child\":\"" ++ child_id ++ "\"}", "cleared_inputs" },
    };
    for (cases) |case| {
        const answer = try invokeAgent(host, case[0], case[1]);
        defer std.testing.allocator.free(answer.text);
        try std.testing.expect(!answer.is_error);
        try std.testing.expect(std.mem.indexOf(u8, answer.text, case[2]) != null);
    }
    try host.evalModule("child.session.origin.site.session_id = 'other';", "foreign.js");
    const foreign = try invokeAgent(host, "stop_agent", "{\"child\":\"" ++ child_id ++ "\"}");
    defer std.testing.allocator.free(foreign.text);
    try std.testing.expect(foreign.is_error);
    try host.evalModule(
        \\import { presenters } from "yuke:transcript";
        \\const spawn = presenters.spawn_agent.present({ agent: "review", message: "x" });
        \\const fallback = presenters.spawn_agent.present({ message: "x" });
        \\const send = presenters.send_agent_input.present({ child: "abc" });
        \\globalThis.presented = spawn.verb === "Agent" && spawn.subject === "review" && fallback.subject === "default" && send.verb === "Send" && send.subject === "abc" ? 1 : 0;
    , "present.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("presented"));
    // A dispose withdraws the tools and the presenters it installed.
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { presenters } from "yuke:transcript";
        \\plugins.dispose("agents");
        \\globalThis.presentersGone = ["spawn_agent", "send_agent_input", "stop_agent"].every((name) => presenters[name] === undefined) ? 1 : 0;
    , "dispose.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("presentersGone"));
    for ([_][]const u8{ "spawn_agent", "send_agent_input", "stop_agent" }) |name| try std.testing.expect(!hasTool(host, name));
}

test "the plugin ends a root prompt with the rule and scopes a child by its row" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    const tools = "[{\"name\":\"read\"},{\"name\":\"exec\"},{\"name\":\"write\"}]";
    const Build = struct { type: []const u8, value: struct { system: []const u8, tools: []const struct { name: []const u8 } } };
    const root_text = try answerHook(host, "request.build", "{\"model\":\"m\",\"system\":\"base\",\"tools\":" ++ tools ++ ",\"max_output_tokens\":1,\"context\":{\"session_id\":\"" ++ root_id ++ "\",\"parent_id\":null,\"agent_name\":\"root\",\"workspace\":\"/w\"}}");
    defer std.testing.allocator.free(root_text);
    const root_build = try std.json.parseFromSlice(Build, std.testing.allocator, root_text, .{ .ignore_unknown_fields = true });
    defer root_build.deinit();
    try std.testing.expectEqualStrings("replace", root_build.value.type);
    try std.testing.expect(std.mem.startsWith(u8, root_build.value.value.system, "base\n\nDo not spawn a child unless the user asks"));
    try std.testing.expectEqual(@as(usize, 3), root_build.value.value.tools.len);
    const child_text = try answerHook(host, "request.build", "{\"model\":\"m\",\"system\":\"base\",\"tools\":" ++ tools ++ ",\"max_output_tokens\":1,\"context\":{\"session_id\":\"" ++ child_id ++ "\",\"parent_id\":\"" ++ root_id ++ "\",\"agent_name\":\"review\",\"workspace\":\"/w\"}}");
    defer std.testing.allocator.free(child_text);
    const child_build = try std.json.parseFromSlice(Build, std.testing.allocator, child_text, .{ .ignore_unknown_fields = true });
    defer child_build.deinit();
    try std.testing.expectEqualStrings("base\n\nReview only. Do not edit.", child_build.value.value.system);
    try std.testing.expectEqual(@as(usize, 3), child_build.value.value.tools.len);
    // A child outside the catalog, or a row without a prompt, keeps the round as it is.
    const ghost = try answerHook(host, "request.build", "{\"model\":\"m\",\"system\":\"base\",\"tools\":[],\"max_output_tokens\":1,\"context\":{\"session_id\":\"" ++ child_id ++ "\",\"parent_id\":\"" ++ root_id ++ "\",\"agent_name\":\"ghost\",\"workspace\":\"/w\"}}");
    defer std.testing.allocator.free(ghost);
    // An empty answer is the proceed decision.
    try std.testing.expectEqualStrings("", ghost);
    const plain = try answerHook(host, "request.build", "{\"model\":\"m\",\"system\":\"base\",\"tools\":" ++ tools ++ ",\"max_output_tokens\":1,\"context\":{\"session_id\":\"" ++ child_id ++ "\",\"parent_id\":\"" ++ root_id ++ "\",\"agent_name\":\"small\",\"workspace\":\"/w\"}}");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("", plain);
    // tools.select runs once per run: a child at the depth limit keeps only its row tools, and agent tools never reach it.
    const Select = struct { type: []const u8, value: struct { tools: []const []const u8 } };
    const every = "\"tools\":[\"edit\",\"exec\",\"read\",\"send_agent_input\",\"spawn_agent\",\"stop_agent\",\"write\"]";
    const review = try answerHook(host, "tools.select", "{" ++ every ++ ",\"context\":{\"session_id\":\"" ++ child_id ++ "\",\"parent_id\":\"" ++ root_id ++ "\",\"depth\":1,\"agent_name\":\"review\",\"workspace\":\"/w\",\"has_skills\":true}}");
    defer std.testing.allocator.free(review);
    const review_select = try std.json.parseFromSlice(Select, std.testing.allocator, review, .{ .ignore_unknown_fields = true });
    defer review_select.deinit();
    try std.testing.expectEqual(@as(usize, 2), review_select.value.value.tools.len);
    try std.testing.expectEqualStrings("exec", review_select.value.value.tools[0]);
    try std.testing.expectEqualStrings("read", review_select.value.value.tools[1]);
    const small = try answerHook(host, "tools.select", "{" ++ every ++ ",\"context\":{\"session_id\":\"" ++ child_id ++ "\",\"parent_id\":\"" ++ root_id ++ "\",\"depth\":1,\"agent_name\":\"small\",\"workspace\":\"/w\",\"has_skills\":true}}");
    defer std.testing.allocator.free(small);
    const small_select = try std.json.parseFromSlice(Select, std.testing.allocator, small, .{ .ignore_unknown_fields = true });
    defer small_select.deinit();
    try std.testing.expectEqual(@as(usize, 4), small_select.value.value.tools.len);
    try std.testing.expectEqualStrings("write", small_select.value.value.tools[3]);
    // A root below the depth limit keeps every tool.
    const root_select = try answerHook(host, "tools.select", "{" ++ every ++ ",\"context\":{\"session_id\":\"" ++ root_id ++ "\",\"parent_id\":null,\"depth\":0,\"agent_name\":\"root\",\"workspace\":\"/w\",\"has_skills\":true}}");
    defer std.testing.allocator.free(root_select);
    try std.testing.expectEqualStrings("", root_select);
}

test "report previews fold independently of their stored text and queue clear preserves reports" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try support.eval(host, "agents/report-ui.test.js");
    try support.expectString(host, "result", "ok");
}

test "agent picker opens children stops one or all and retains focused interrupt scope" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try support.eval(host, "agents/agent-picker.test.js");
    try support.expectString(host, "result", "ok");
}

test "TUI tool questions show their owner and device login closes on completion" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/owner-question.test.js");
    const call = host.calls.submit("question", "{}", "/work");
    defer call.finish();
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].opts.title.includes('01010101') ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.length === 2 ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.map(answer => root.overlays[0].content.list.format(answer)).join('|') === 'Connect|Later' ? 1 : 0"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.body.includes('/auth.') ? 1 : 0"));
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
    try support.eval(host, "agents/fixture.js");
    try support.eval(host, "agents/finder-mocks.test.js");
    try support.eval(host, "agents/finder.test.js");
    for (0..4) |_| try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays.length"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.length"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source[0].id === 'parent' ? 1 : 0"));
}

test "JavaScript leaves child prompt composition to native admission" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/child-prompt.test.js");
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
    try support.eval(host, "agents/tree.test.js");
    try support.expectString(host, "result", "root:0,a:1,b:2,sibling:1");
}

test "agent rows reject cyclic ancestry" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(tree_fixture, "tree-fixture.js");
    try support.eval(host, "agents/cycle.test.js");
    try support.expectString(host, "result", "The session ancestry contains a cycle.");
}

test "agent activity refresh retains selection and handles concurrent reload or close" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try support.eval(host, "agents/refresh.test.js");
    try support.expectString(host, "result", "ok");
}

test "dirty overflow refreshes a picker even beside unrelated index facts" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "agents/fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try support.eval(host, "agents/overflow.test.js");
    try support.expectString(host, "result", "ready");
    try host.evalModule("child.activity.state = { type: 'streaming' };", "changed.js");
    const sink = host.engine.eventSink();
    for (0..@import("../native/engine/digest.zig").max_dirty_sessions) |n| {
        sink.on_event(sink.ctx, .{ .method = .@"session.removed", .params = .{ .session_removed_data = .{
            .session_id = .bytes(std.mem.toBytes(@as(u128, n + 1000))),
            .revision = 1,
        } } });
    }
    sink.on_event(sink.ctx, .{ .method = .@"session.activity_changed", .params = .{ .session_activity_changed_data = .{
        .session_id = .bytes([_]u8{2} ** 16),
        .activity = .{ .state = .{ .idle = .{} }, .config = null, .queued = 0, .context_usage = .zero, .pending_compaction = null },
    } } });
    sink.on_event(sink.ctx, .{ .method = .notice, .params = .{ .notice = .{ .level = .info, .source = "bench", .message = "unrelated" } } });
    try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("picker.win.opts.title.includes('1 active') ? 1 : 0"));
    try host.evalModule("picker.content.cancel(); chat.sessionId = null; chat.dispose();", "close.js");
}
