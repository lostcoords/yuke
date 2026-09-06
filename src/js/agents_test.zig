//! Setup tests replace the client boundary and keep the real promise coordinator.

const std = @import("std");
const Host = @import("host.zig").Host;
const proto = @import("proto");

fn expect(host: *Host, want: []const u8) !void {
    for (0..4) |_| try host.pump();
    const value = try host.ctx.eval("globalThis.result", "result.js", .{});
    defer host.ctx.freeValue(value);
    const text = try host.ctx.toCStringLen(value);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings(want, text);
}

const fixture =
    \\import { client } from "yuke:client";
    \\import { spawnAgent, recoverAgent } from "yuke:agents";
    \\globalThis.client = client;
    \\globalThis.spawnAgent = spawnAgent;
    \\globalThis.recoverAgent = recoverAgent;
    \\globalThis.map = { path: "/config/agents.json", revision: "1", config: { models: {} } };
    \\globalThis.stats = { prompts: 0, saves: 0, creates: 0, gets: 0, changes: 0 };
    \\const clone = (value) => JSON.parse(JSON.stringify(value));
    \\client.agentsGet = async () => clone(globalThis.map);
    \\client.agentsUpdate = async (next) => {
    \\  if (next.revision !== map.revision) throw Object.assign(new Error("stale"), { code: "config_conflict" });
    \\  stats.saves++; map = { ...map, revision: String(Number(map.revision) + 1), config: clone(next.config) }; return clone(map);
    \\};
    \\client.agentsResolve = async (slot) => {
    \\  const entry = map.config.models[slot];
    \\  if (!entry) throw Object.assign(new Error("setup"), { code: "setup_required" });
    \\  return { slot, model: entry.model, reasoning: entry.reasoning || "medium", revision: map.revision };
    \\};
    \\client.catalogList = async () => ({ type: "full", providers: [{ id: "p", state: "ready" }], models: [{ provider: "p", selector: "p/family/model", name: "model", supports_tools: true, reasoning_levels: ["low", "medium", "high"], default_reasoning: "medium", cost: { input: 1, output: 2 } }] });
    \\client.sessionGet = async () => { stats.gets++; return { session: { id: "parent", root: "/work", model: "parent/large", origin: { type: "root" } } }; };
    \\client.sessionCreate = async (params) => { const selected = await client.agentsResolve(params.child.slot); stats.creates++; globalThis.created = params; return { session: { id: "child", model: selected.model }, input: { type: "queued", input_id: 1, reason: "concurrency_limit", capacity: { active: 8, limit: 8 } } }; };
    \\client.agentsSetModel = async () => { stats.changes++; return { config: { config_rev: 1 } }; };
    \\globalThis.ctx = { interaction: { interactive: true,
    \\  confirm: async () => { stats.prompts++; return true; },
    \\  select: async (_title, options) => options[0],
    \\  input: async () => "key", notify: () => {},
    \\} };
    \\globalThis.site = { sessionId: "parent", messageId: 2, partId: 0 };
    \\globalThis.result = "pending";
;

test "setup coalesces both slots and continues one atomic spawn per caller" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\(async () => {
        \\  const results = await Promise.all([
        \\    spawnAgent(ctx, { name: "one", message: "task one", model: "small" }, undefined, site),
        \\    spawnAgent(ctx, { name: "two", message: "task two", model: "medium" }, undefined, site),
        \\  ]);
        \\  if (stats.saves !== 1 || stats.prompts !== 2 || stats.creates !== 2) throw new Error(JSON.stringify(stats));
        \\  if (results[0].slot !== "small" || results[1].model !== "p/family/model" || results[0].input.reason !== "concurrency_limit") throw new Error("receipt");
        \\  if (created.model || created.reasoning || !created.initial_input || created.child.site.message_id !== 2) throw new Error("admission");
        \\  await spawnAgent(ctx, { name: "three", message: "task", model: "small" }, undefined, site);
        \\  if (stats.prompts !== 2 || stats.saves !== 1) throw new Error("repeat setup");
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "coalesce.js");
    try expect(host, "ok");
}

test "required slots headless setup and user cancellation have no child side effects" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\(async () => {
        \\  for (const model of [undefined, null, "large", "p/model"]) {
        \\    try { await spawnAgent(ctx, { name: "one", message: "task", model }, undefined, site); throw new Error("accepted"); }
        \\    catch (e) { if (e.code !== "bad_request") throw e; }
        \\  }
        \\  if (stats.gets || stats.prompts) throw new Error("validation ran too late");
        \\  ctx.interaction.interactive = false;
        \\  try { await spawnAgent(ctx, { name: "headless", message: "task", model: "small" }, undefined, site); throw new Error("headless accepted"); }
        \\  catch (e) { if (e.code !== "setup_required") throw e; }
        \\  ctx.interaction.interactive = true;
        \\  ctx.interaction.confirm = async () => false;
        \\  try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, undefined, site); throw new Error("canceled accepted"); }
        \\  catch (e) { if (e.code !== "setup_declined") throw e; }
        \\  ctx.interaction.confirm = async () => undefined;
        \\  try { await spawnAgent(ctx, { name: "dismissed", message: "task", model: "small" }, undefined, site); throw new Error("dismissed accepted"); }
        \\  catch (e) { if (e.code !== "setup_canceled") throw e; }
        \\  if (stats.saves || stats.creates) throw new Error("side effect");
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "refusals.js");
    try expect(host, "ok");
}

test "setup preserves concurrent slot choices and propagates a failed save" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\(async () => {
        \\  ctx.interaction.confirm = async () => { map.revision = "2"; map.config.models.medium = { model: "other/model" }; return true; };
        \\  await spawnAgent(ctx, { name: "saved", message: "task", model: "small" }, undefined, site);
        \\  if (map.config.models.medium.model !== "other/model" || map.config.models.small.model !== "p/family/model") throw new Error("lost edit");
        \\  map.config.models = {};
        \\  ctx.interaction.confirm = async () => true;
        \\  client.agentsUpdate = async () => { throw Object.assign(new Error("disk full"), { code: "runtime_failed" }); };
        \\  try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, undefined, site); throw new Error("save accepted"); }
        \\  catch (e) { if (e.code !== "runtime_failed") throw e; }
        \\  if (stats.creates !== 1) throw new Error("spawn after save failure");
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "save-conflict.js");
    try expect(host, "ok");
}

test "model repair changes a child without a new run or an implicit slot edit" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\(async () => {
        \\  ctx.interaction.select = async (title, options) => title === "Subagent needs attention" ? options[2] : options[0];
        \\  ctx.interaction.confirm = async () => false;
        \\  await recoverAgent(ctx, "child", "small");
        \\  if (stats.changes !== 1 || stats.saves || stats.creates) throw new Error(JSON.stringify(stats));
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "repair.js");
    try expect(host, "ok");
}

test "tool cancellation removes the setup question and rejects a late answer" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { rpcInteractionPlugin } from "yuke:interaction";
        \\plugins.use(rpcInteractionPlugin);
        \\plugins.use({ name: "agent-test", apply(ctx) {
        \\  ctx.tools.define({ name: "spawn-test", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
        \\    try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, signal, site); result = "spawned"; }
        \\    catch (e) { result = e.code || e.message; }
        \\    return { text: result };
        \\  } });
        \\} });
    , "tool.js");
    const call = host.calls.submit("spawn-test", "{}", "/work");
    call.site = .{ .session_id = .bytes([_]u8{1} ** 16), .message_id = 2, .part_id = 0 };
    try host.pump();
    const question = host.interactions.takeNext().?;
    try std.testing.expect(question.request == .confirm);
    try std.testing.expectEqual(proto.ids.SessionId.bytes([_]u8{1} ** 16), question.session_id.?);
    call.finish();
    try expect(host, "tool_cancelled");
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.creates"));
    try std.testing.expectError(error.Unknown, host.interactions.respond(.{ .interaction_id = question.interaction_id, .response = .{ .confirm = .{ .value = true } } }));
}

test "a canceled tool cannot spawn after its pending config save succeeds" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\const save = client.agentsUpdate;
        \\client.agentsUpdate = (next) => new Promise((resolve) => { globalThis.finishSave = async () => resolve(await save(next)); });
        \\plugins.use({ name: "agent-test", apply(plugin) {
        \\  plugin.tools.define({ name: "spawn-test", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
        \\    try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, signal, site); result = "spawned"; }
        \\    catch (e) { result = e.code || e.message; }
        \\    return { text: result };
        \\  } });
        \\} });
    , "late-save.js");
    const call = host.calls.submit("spawn-test", "{}", "/work");
    try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("typeof finishSave === 'function' ? 1 : 0"));
    call.finish();
    try expect(host, "tool_cancelled");
    try host.evalModule("finishSave();", "save.js");
    try expect(host, "tool_cancelled");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("stats.saves"));
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.creates"));
    try std.testing.expectEqual(@as(usize, 0), host.interactions.live.items.len);
}

test "a live setup follower resumes after the lead tool is canceled" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { rpcInteractionPlugin } from "yuke:interaction";
        \\plugins.use(rpcInteractionPlugin);
        \\plugins.use({ name: "agent-test", apply(ctx) {
        \\  for (const name of ["one", "two"]) ctx.tools.define({ name, description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
        \\    try { await spawnAgent(ctx, { name, message: "task", model: "small" }, signal, site); globalThis[name] = "spawned"; }
        \\    catch (e) { globalThis[name] = e.code || e.message; }
        \\    return { text: globalThis[name] };
        \\  } });
        \\} });
    , "follower.js");
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
    for (0..2) |_| {
        try host.pump();
        const pick = host.interactions.takeNext().?;
        try std.testing.expect(pick.request == .select);
        try host.interactions.respond(.{ .interaction_id = pick.interaction_id, .response = .{ .select = .{ .value = pick.request.select.options[0] } } });
    }
    try host.pump();
    const both = host.interactions.takeNext().?;
    try host.interactions.respond(.{ .interaction_id = both.interaction_id, .response = .{ .confirm = .{ .value = true } } });
    try host.pump();
    try host.evalModule("result = one + '/' + two + '/' + stats.creates;", "result.js");
    try expect(host, "tool_cancelled/spawned/1");
}

test "cancellation watch refusal is an operating error and does not retry setup" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\ctx.interaction.confirm = () => new Promise(() => {});
        \\spawnAgent(ctx, { name: "invalid", message: "task", model: "small" }, { aborted: false }, site).then(() => result = "accepted", (e) => result = e.code);
    , "invalid-signal.js");
    try expect(host, "runtime_failed");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("stats.saves + stats.creates"));
}

test "first use connects an API key provider with a secret prompt" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\(async () => {
        \\  const list = client.catalogList;
        \\  let ready = false;
        \\  client.catalogList = async () => { const c = await list(); c.providers[0].state = ready ? "ready" : "needs_api_key"; return c; };
        \\  client.authList = async () => ({ providers: [{ provider_id: "p", can_login: false }] });
        \\  ctx.interaction.input = async (_title, _placeholder, options) => { if (!options.secret) throw new Error("visible key"); return "secret"; };
        \\  client.authSetApiKey = async (id, key) => { if (id !== "p" || key !== "secret") throw new Error("credential"); ready = true; };
        \\  client.catalogReload = async () => {};
        \\  await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, undefined, site);
        \\  if (!ready || stats.saves !== 1 || stats.creates !== 1) throw new Error(JSON.stringify(stats));
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "api-key.js");
    try expect(host, "ok");
}

test "shared credential repair handles a login result before the start response" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { events } from "yuke:core";
        \\(async () => {
        \\  map.config.models = { small: { model: "p/family/model" }, medium: { model: "p/family/model" } };
        \\  const resolve = client.agentsResolve;
        \\  let ready = false, logins = 0;
        \\  client.agentsResolve = async (slot) => { if (!ready) throw Object.assign(new Error("key expired"), { code: "auth_required" }); return resolve(slot); };
        \\  client.authList = async () => ({ providers: [{ provider_id: "p", can_login: true }] });
        \\  client.authLogin = async () => {
        \\    logins++;
        \\    events.emit("auth.login_finished", { type: "index", facts: ["auth.login_finished"], auth: [{ method: "auth.login_finished", params: { login_id: "login", provider_id: "p", outcome: { type: "succeeded" } } }] });
        \\    ready = true;
        \\    return { login_id: "login", verification_url: "https://example.com/login", user_code: "code" };
        \\  };
        \\  client.catalogReload = async () => {};
        \\  client.authCancelLogin = async () => { throw new Error("canceled success"); };
        \\  await Promise.all([spawnAgent(ctx, { name: "repair-small", message: "task", model: "small" }, undefined, site), spawnAgent(ctx, { name: "repair-medium", message: "task", model: "medium" }, undefined, site)]);
        \\  if (logins !== 1 || stats.saves !== 0 || stats.creates !== 2) throw new Error("duplicate repair");
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "shared-login.js");
    try expect(host, "ok");
}

test "tool cancellation stops its pending device login without child admission" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\map.config.models.small = { model: "p/family/model" };
        \\globalThis.canceledLogin = "";
        \\client.agentsResolve = async () => { throw Object.assign(new Error("expired"), { code: "auth_required" }); };
        \\client.authList = async () => ({ providers: [{ provider_id: "p", can_login: true }] });
        \\client.authLogin = async () => ({ login_id: "login", verification_url: "https://example.com/login", user_code: "code" });
        \\client.authCancelLogin = async (id) => { canceledLogin = id; };
        \\plugins.use({ name: "agent-test", apply(plugin) {
        \\  plugin.tools.define({ name: "spawn-test", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
        \\    try { await spawnAgent(ctx, { name: "one", message: "task", model: "small" }, signal, site); result = "spawned"; }
        \\    catch (e) { result = e.code || e.message; }
        \\    return { text: result };
        \\  } });
        \\} });
    , "cancel-login.js");
    const call = host.calls.submit("spawn-test", "{}", "/work");
    try host.pump();
    try std.testing.expect(host.interactions.live.items.len > 0);
    call.finish();
    try expect(host, "tool_cancelled");
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
    \\client.sessionSendInput = async (id, text, site) => { if (id !== child.session.id || text !== "more" || site.message_id !== 2) throw new Error("instruction"); return { type: "queued", reason: "session_busy", input_id: 2, capacity: { active: 1, limit: 8 } }; };
    \\client.sessionCancelRun = async (id, clear) => { if (id !== child.session.id || !clear) throw new Error("stop scope"); return { canceled_run: null, cleared_inputs: [2] }; };
    \\client.sessionHistory = async (params) => { if (params.session_id !== child.session.id || params.before_message_id !== 0) throw new Error("history scope"); return { messages: [{ id: 3, type: "assistant", content: [{ type: "text", text: "x".repeat(70 * 1024) + "full child tail" }] }], has_more: true, configs: [] }; };
;

test "nested child spawn delegates depth and child identity to native" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { defineConfig } from "yuke:kernel";
        \\import { spawnAgent } from "yuke:agents";
        \\const child = "02".repeat(16);
        \\client.sessionGet = async (id) => ({ session: { id, root: "/work", origin: { type: "child", site: { session_id: "01".repeat(16) } } } });
        \\client.sessionCreate = async (params) => { globalThis.created = params; return { session: { id: child, model: "native/model" }, input: { type: "queued" } }; };
        \\const spawned = await spawnAgent(ctx, { name: "b", message: "task", model: "small" }, undefined, { sessionId: child, messageId: 1, partId: 0 });
        \\if (spawned.name !== "b" || spawned.model !== "native/model" || created.model || created.reasoning) throw new Error("native admission");
        \\globalThis.result = "ok";
    , "nested.js");
    try expect(host, "ok");
}

test "agent tools expose explicit slots and truthful reusable child receipts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try std.testing.expectEqual(@as(usize, 5), host.tools.entries.items.len);
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
    try std.testing.expect(std.mem.indexOf(u8, spawn.text, "concurrency_limit") != null);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("created.child.slot === 'small' && stats.creates === 1 ? 1 : 0"));
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "send_agent_input", "{\"child\":\"one\",\"message\":\"more\"}", "session_busy" },
        .{ "stop_agent", "{\"child\":\"one\"}", "cleared_inputs" },
        .{ "list_agents", "{}", "\"name\":\"one\"" },
        .{ "read_agent", "{\"child\":\"one\"}", "next_before_message_id\":3" },
    };
    for (cases) |case| {
        const answer = try invokeAgent(host, case[0], case[1]);
        defer std.testing.allocator.free(answer.text);
        try std.testing.expect(!answer.is_error);
        try std.testing.expect(std.mem.indexOf(u8, answer.text, case[2]) != null);
        if (std.mem.eql(u8, case[0], "read_agent")) {
            try std.testing.expect(answer.text.len > 64 * 1024);
            try std.testing.expect(std.mem.indexOf(u8, answer.text, "full child tail") != null);
        }
    }
    try host.evalModule("child.session.origin.site.session_id = 'other';", "foreign.js");
    const foreign = try invokeAgent(host, "stop_agent", "{\"child\":\"02020202020202020202020202020202\"}");
    defer std.testing.allocator.free(foreign.text);
    try std.testing.expect(foreign.is_error);
}

test "report previews fold independently of their stored text and queue clear preserves reports" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { Transcript, inputSourceLabel } from "yuke:transcript";
        \\import { clearWorkQueue, queuedText } from "yuke:queue";
        \\(async () => {
        \\  const source = { type: "child_report", name: "one", outcome: { type: "turn" }, partial: false, truncated: false };
        \\  const full = Array.from({ length: 200 }, (_, i) => "line " + i).join("\n");
        \\  const t = new Transcript({ textOf: () => full });
        \\  t.setOutline([{ id: 1, type: "user", source }], null);
        \\  if (t.rowCount(80) > 15 || !inputSourceLabel(source).includes("one")) throw new Error("unfolded report");
        \\  t.togglePart(1, -1);
        \\  if (t.rowCount(80) < 200) throw new Error("lost full report");
        \\  t.togglePart(1, -1);
        \\  if (t.rowCount(80) > 15) throw new Error("cannot fold");
        \\  const report = { input_id: 3, source, content: [{ type: "text", text: full }] };
        \\  const inputs = [{ input_id: 1 }, { input_id: 2, source: { type: "parent_instruction" } }, report];
        \\  client.sessionQueue = async () => ({ items: inputs });
        \\  const canceled = [];
        \\  client.sessionCancelInput = async (_id, inputId) => { canceled.push(inputId); if (inputId === 2) throw new Error("started"); return { canceled_input: inputId }; };
        \\  const result = await clearWorkQueue("parent");
        \\  if (result.removed !== 1 || result.failed !== 1 || result.protected !== 1 || canceled.includes(3)) throw new Error("bad queue count");
        \\  if (!queuedText(report).startsWith("[protected]") || report.content[0].text !== full) throw new Error("report mutation");
        \\  globalThis.result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "report-ui.js");
    try expect(host, "ok");
}

test "agent picker opens children stops one or all and retains focused interrupt scope" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(tool_fixture, "tools.js");
    try host.evalModule(
        \\import { root, Node, events } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\import { Chat } from "yuke:chat";
        \\import { openAgents, childState } from "yuke:agents-ui";
        \\plugins.use(tuiPlugin);
        \\plugins.use({ name: "picker-test", apply(ctx) {
        \\  ctx.inject(["tui"], (ctx) => { (async () => {
        \\    const chat = new Chat();
        \\    root.setRoot(new Node(chat.view)); root.focusView(chat.view);
        \\    const stopped = [];
        \\    client.sessionCancelRun = async (id, clear) => { stopped.push([id, clear]); return {}; };
        \\    client.sessionOpen = () => true;
        \\    client.sessionClose = () => {};
        \\    client.sessionOutline = () => ({ messages: [], active: null });
        \\    chat.sessionId = "01".repeat(16);
        \\    const picker = await openAgents(ctx, chat.sessionId);
        \\    if (!childState(child).includes("completed") || picker.content.source.length !== 2) throw new Error("child row");
        \\    if (!picker.win.opts.title.includes("0 active")) throw new Error("initial summary");
        \\    picker.content.onKey({ type: "key", code: "char", char: "x", mods: 0 });
        \\    if (stopped.length) throw new Error("main stopped");
        \\    child.activity.state = { type: "running_tool", tool_name: "search" };
        \\    events.emit("session.changed", { type: "session", session: child.session.id, facts: ["session.activity_changed"] });
        \\    for (let i = 0; i < 12; i++) await Promise.resolve();
        \\    if (!picker.win.opts.title.includes("1 active") || !childState(child).includes("search")) throw new Error("live summary");
        \\    picker.content.list.move(1);
        \\    picker.content.onKey({ type: "key", code: "char", char: "x", mods: 0 });
        \\    await Promise.resolve(); await Promise.resolve();
        \\    picker.content.onKey({ type: "key", code: "char", char: "X", mods: 0 });
        \\    for (let i = 0; i < 12; i++) await Promise.resolve();
        \\    if (stopped.length !== 2 || stopped.some(([id, clear]) => id !== child.session.id || clear !== true)) throw new Error("stop scope");
        \\    picker.content.onKey({ type: "key", code: "enter", mods: 0 });
        \\    if (chat.sessionId !== child.session.id || root.overlays.length) throw new Error("open child");
        \\    chat.interrupt();
        \\    if (stopped.length !== 3 || stopped[2][0] !== child.session.id || stopped[2][1] !== undefined) throw new Error("interrupt changed scope");
        \\    const back = await openAgents(ctx, chat.sessionId);
        \\    back.content.list.move(-1);
        \\    back.content.accept();
        \\    if (chat.sessionId !== "01".repeat(16)) throw new Error("open main");
        \\    const stale = openAgents(ctx, chat.sessionId);
        \\    chat.sessionId = child.session.id;
        \\    if (await stale || root.overlays.length) throw new Error("stale picker opened");
        \\    chat.dispose();
        \\    result = "ok";
        \\  })().catch((e) => result = e.stack || e.message); });
        \\} });
    , "agent-picker.js");
    try expect(host, "ok");
}

test "TUI tool questions show their owner and device login closes on completion" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { root } from "yuke:core";
        \\import { tuiPlugin } from "yuke:tui";
        \\import { tuiInteractionPlugin } from "yuke:interaction-ui";
        \\plugins.use(tuiPlugin); plugins.use(tuiInteractionPlugin);
        \\globalThis.result = "pending";
        \\plugins.use({ name: "question", apply(ctx) {
        \\  ctx.tools.define({ name: "question", description: "test", parameters: { type: "object", properties: {} }, execute: async (_args, signal) => {
        \\    await ctx.interaction.confirm("Proceed?", "Small is for narrow research and simple edits. Medium is for broader work and review. You can use one model for both slots. Change these choices later with /agent-models.", { signal, labels: { accept: "Configure models", cancel: "Later" } });
        \\    const completion = new Promise((resolve) => globalThis.finishLogin = resolve);
        \\    const outcome = await ctx.interaction.deviceLogin({ verification_url: "https://example.com", user_code: "abc" }, completion, { signal });
        \\    result = outcome?.type || "canceled";
        \\    return result;
        \\  } });
        \\} });
        \\globalThis.root = root;
    , "owner-question.js");
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
    try expect(host, "succeeded");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("root.overlays.length"));
}

test "the top-level session picker excludes child sessions" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\import { tuiPlugin } from "yuke:tui";
        \\plugins.use(tuiPlugin);
        \\client.sessionList = async () => ({ items: [
        \\  { session: { id: "parent", title: "parent", origin: { type: "root" } }, activity: { state: { type: "idle" } } },
        \\  { session: { id: "child", title: "child", origin: { type: "child" } }, activity: { state: { type: "idle" } } },
        \\], total: 2 });
    , "finder-mocks.js");
    try host.evalModule(
        \\import { openSessionFinder } from "yuke:defaults";
        \\import { root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\globalThis.root = root;
        \\plugins.use({ name: "finder-test", apply(ctx) { ctx.inject(["tui"], (ctx) => { openSessionFinder(ctx); }); } });
    , "finder.js");
    for (0..4) |_| try host.pump();
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays.length"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source.length"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("root.overlays[0].content.source[0].id === 'parent' ? 1 : 0"));
}

test "a user tool can replace a stock agent tool without a boot failure" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\plugins.use({ name: "custom-agent", apply(ctx) {
        \\  ctx.tools.define({ name: "spawn_agent", description: "custom", parameters: { type: "object", properties: {} }, execute: async () => "custom agent" });
        \\} });
    , "custom-agent.js");
    try host.evalModule(tool_fixture, "tools.js");
    const result = try invokeAgent(host, "spawn_agent", "{}");
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("custom agent", result.text);
    try std.testing.expectEqual(@as(usize, 5), host.tools.entries.items.len);
}

test "stop all distinguishes changed idle and failed children" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { stopAllChildren } from "yuke:agent-tools";
        \\(async () => {
        \\  client.sessionList = async () => ({ items: ["active", "idle", "foreign-owner"].map((id) => ({ session: { id } })), next_cursor: null });
        \\  client.sessionCancelRun = async (id) => { if (id === "foreign-owner") throw new Error("busy"); return { canceled_run: id === "active" ? 1 : null, cleared_inputs: [] }; };
        \\  const stopped = await stopAllChildren("parent");
        \\  if (stopped.stopped !== 1 || stopped.unchanged !== 1 || stopped.failed !== 1) throw new Error(JSON.stringify(stopped));
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "stop-all.js");
    try expect(host, "ok");
}

test "JavaScript supplies the default child prompt before input hooks" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { plugins, createSession } from "yuke:ext";
        \\import { config } from "yuke:kernel";
        \\config.systemPrompt = "base prompt";
        \\const prompts = [];
        \\plugins.use({ name: "inspect-prompt", apply(ctx) {
        \\  ctx.hook("input.before", (input) => { prompts.push(input.create.system_prompt); return { block: "test" }; });
        \\} });
        \\(async () => {
        \\  const params = { workspace_path: "/work", child: { name: "child", slot: "small", site: {} }, initial_input: { type: "content", content: [{ type: "text", text: "task" }] } };
        \\  for (const value of [params, { ...params, system_prompt: "custom" }]) {
        \\    try { await createSession(value); throw new Error("input was not blocked"); }
        \\    catch (error) { if (error.code !== "bad_request") throw error; }
        \\  }
        \\  if (!prompts[0].startsWith("base prompt\n\n") || !prompts[0].includes("Delegate only when a spawn tool is available")) throw new Error("missing policy");
        \\  if (prompts[1] !== "custom") throw new Error("lost custom prompt");
        \\  globalThis.result = "ok";
        \\})().catch((error) => globalThis.result = error.message);
    , "child-prompt.js");
    try expect(host, "ok");
}

test "setup cancellation rows are neutral and errors remain visible" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(
        \\import { Transcript, rowText } from "yuke:transcript";
        \\for (const [reason, label] of [["setup_declined", "Setup declined"], ["setup_dismissed", "Setup incomplete"]]) {
        \\  const t = new Transcript({ textOf: () => "", partsOf: () => [{ type: "tool", id: 0, name: "spawn_agent", arguments: "{}", state: { type: "canceled", reason, duration_ms: 2 } }] });
        \\  t.setOutline([{ id: "one", type: "assistant" }], null);
        \\  const rows = t.rows(100, 0, 10);
        \\  if (!rows.map(rowText).join(" ").includes(label + " · No agent created")) throw new Error("missing outcome");
        \\  if (rows.some(row => row.group === "TxToolError" || row.segments?.some(s => s.group === "TxToolError"))) throw new Error("red cancellation");
        \\}
        \\const t = new Transcript({ textOf: () => "", partsOf: () => [{ type: "tool", id: 0, name: "spawn_agent", arguments: "{}", state: { type: "error", error: "disk full" } }] });
        \\t.setOutline([{ id: "one", type: "assistant" }], null);
        \\if (!t.rows(100, 0, 10).map(rowText).join(" ").includes("disk full")) throw new Error("hidden error");
        \\globalThis.result = "ok";
    , "cancellation-rows.js");
    try expect(host, "ok");
}

test "explicit model edits skip onboarding and change only the selected slot" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(fixture, "fixture.js");
    try host.evalModule(
        \\import { editSlot } from "yuke:agents";
        \\(async () => {
        \\  ctx.interaction.confirm = async () => { throw new Error("unexpected onboarding"); };
        \\  await editSlot(ctx, "small");
        \\  if (map.config.models.small.model !== "p/family/model" || map.config.models.medium || stats.creates) throw new Error("wrong edit scope");
        \\  await editSlot(ctx, "medium");
        \\  if (stats.saves !== 2 || map.config.models.small.model !== "p/family/model" || map.config.models.medium.model !== "p/family/model") throw new Error("lost slot");
        \\  ctx.interaction.select = async () => undefined;
        \\  await editSlot(ctx, "small");
        \\  if (stats.saves !== 2) throw new Error("canceled edit saved");
        \\  result = "ok";
        \\})().catch((e) => result = e.stack || e.message);
    , "edit-slot.js");
    try expect(host, "ok");
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
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(tree_fixture, "tree-fixture.js");
    try host.evalModule(
        \\import { agentRows } from "yuke:agents-ui";
        \\agentRows("b").then((rows) => result = rows.map((row) => row.item.session.id + ":" + row.depth).join(","), (e) => result = e.message);
    , "tree.js");
    try expect(host, "root:0,a:1,b:2,sibling:1");
}

test "agent rows reject cyclic ancestry" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try host.evalModule(tree_fixture, "tree-fixture.js");
    try host.evalModule(
        \\import { agentRows } from "yuke:agents-ui";
        \\nodes.a.session.origin.site.session_id = "b";
        \\agentRows("b").then(() => result = "accepted", (e) => result = e.message);
    , "cycle.js");
    try expect(host, "The session ancestry contains a cycle.");
}
