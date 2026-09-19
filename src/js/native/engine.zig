//! The native `yuke:engine` module is the JavaScript seam onto the one in-process engine; there is no transport or replica, so a view reads the engine's own session projection; two rules hold this seam together: an event never re-enters JavaScript from an engine task because the sink marks a session dirty and `drain` delivers it on the owner, and a text read is paged so one call copies a bounded number of bytes however large the message is.

const std = @import("std");
const execution = @import("../../execution.zig");
const quickjs = @import("quickjs");
const zio = @import("zio");
const proto = @import("proto");
const host_mod = @import("../host.zig");
const module = @import("module.zig");
const digest = @import("engine/digest.zig");
const paging = @import("engine/paging.zig");
const project = @import("engine/project.zig");
const app = @import("../../app/app.zig");
const pending = @import("../pending.zig");
const engine_call = @import("../../app/call.zig");
const session_events = @import("../../engine/events.zig");
const domain_session = @import("../../session/session.zig");
const Session = domain_session.Session;

const Host = host_mod.Host;
const Context = quickjs.Context;
const Value = quickjs.Value;
const SessionId = proto.ids.SessionId;

/// The handle and the drain live in `engine/digest.zig`; the host and the owner reach them here.
pub const Engine = digest.Engine;
pub const drain = digest.drain;

/// The default prompt uses the protocol string limit.
pub const max_system_prompt_bytes: usize = @intCast(proto.meta.limits.max_message_string_bytes);

/// Register `yuke:engine-native` and its one `native` object.
pub fn install(host: *Host) void {
    module.installObject(host, "yuke:engine-native", "native", &.{
        .{ .name = "setAgentLimits", .arity = 2, .call = jsSetAgentLimits },
        .{ .name = "setPromptConfig", .arity = 2, .call = jsSetPromptConfig },
        .{ .name = "setEventSink", .arity = 1, .call = jsSetEventSink },
        .{ .name = "factNames", .arity = 0, .call = jsFactNames },
        .{ .name = "memoryUsage", .arity = 0, .call = jsMemoryUsage },
        .{ .name = "isBusy", .arity = 0, .call = jsIsBusy },
        .{ .name = "request", .arity = 2, .call = jsRequest },
        .{ .name = "sessionOpen", .arity = 1, .call = jsSessionOpen },
        .{ .name = "sessionClose", .arity = 1, .call = jsSessionClose },
        .{ .name = "sessionOutline", .arity = 1, .call = jsSessionOutline },
        .{ .name = "sessionActivity", .arity = 1, .call = jsSessionActivity },
        .{ .name = "sessionParts", .arity = 2, .call = jsSessionParts },
        .{ .name = "sessionPart", .arity = 3, .call = jsSessionPart },
        .{ .name = "sessionText", .arity = 4, .call = jsSessionText },
        .{ .name = "partText", .arity = 6, .call = jsPartText },
    }, null);
}

// ---------------------------------------------------------------- javascript seam

fn jsIsBusy(ctx: Context, _: Value, _: []const Value) Value {
    return ctx.newBool(Host.fromContext(ctx).engine.isBusy());
}

fn sidArg(ctx: Context, args: []const Value, idx: usize) ?SessionId {
    if (args.len <= idx) return null;
    return module.sessionId(ctx, args[idx]);
}

fn u64Arg(ctx: Context, args: []const Value, idx: usize) ?u64 {
    if (args.len <= idx) return null;
    return module.integer(ctx, args[idx], 0, proto.meta.constants.MAX_WIRE_INTEGER);
}

/// Resolve the live runtime a view reads. A view that never opened the session gets null.
fn runtimeArg(ctx: Context, args: []const Value) ?*Session {
    const runtime = Host.fromContext(ctx).engine.runtime orelse return null;
    const sid = sidArg(ctx, args, 0) orelse return null;
    return runtime.engine.sessions.get(sid);
}

/// `factNames()` answers every fact the engine can publish, so a bus declares them without drift.
fn jsFactNames(ctx: Context, _: Value, _: []const Value) Value {
    const names = ctx.newArray();
    for (std.meta.tags(proto.enums.BroadcastName), 0..) |fact, i| {
        if (ctx.hasException()) break;
        module.setIndex(ctx, names, i, ctx.newString(@tagName(fact)));
    }
    if (ctx.hasException()) {
        ctx.freeValue(names);
        return module.throwPending(ctx);
    }
    return names;
}

/// Return the QuickJS allocation counters, separate from the process footprint.
fn jsMemoryUsage(ctx: Context, _: Value, _: []const Value) Value {
    const usage = Host.fromContext(ctx).runtime.computeMemoryUsage();
    const out = ctx.newObject();
    const fields = [_]struct { [:0]const u8, i64 }{
        .{ "heap", usage.malloc_size },
        .{ "limit", usage.malloc_limit },
        .{ "strings", usage.str_size },
        .{ "stringCount", usage.str_count },
        .{ "objects", usage.obj_size },
        .{ "objectCount", usage.obj_count },
        .{ "properties", usage.prop_size },
        .{ "propertyCount", usage.prop_count },
        .{ "shapes", usage.shape_size },
        .{ "arrayCount", usage.array_count },
        .{ "fastArrayElements", usage.fast_array_elements },
    };
    for (fields) |field| module.set(ctx, out, field[0], ctx.newFloat64(@floatFromInt(field[1])));
    if (ctx.hasException()) {
        ctx.freeValue(out);
        return module.throwPending(ctx);
    }
    return out;
}

fn jsSetEventSink(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    if (args.len < 1 or !ctx.isFunction(args[0])) return ctx.throwTypeError("setEventSink needs a function");
    ctx.freeValue(engine.sink);
    engine.sink = ctx.dupValue(args[0]);
    return quickjs.UNDEFINED;
}

/// Open a view onto one session. The pin keeps the runtime alive while a pane shows it.
fn jsSessionOpen(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.newBool(false);
    const sid = sidArg(ctx, args, 0) orelse return ctx.newBool(false);
    const rt = runtime.engine.activate(sid) catch return ctx.newBool(false);
    rt.pin();
    return ctx.newBool(true);
}

/// Close one view. The runtime may evict after the last pane leaves.
fn jsSessionClose(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return quickjs.UNDEFINED;
    const sid = sidArg(ctx, args, 0) orelse return quickjs.UNDEFINED;
    const rt = runtime.engine.sessions.get(sid) orelse return quickjs.UNDEFINED;
    rt.unpin();
    runtime.engine.sessions.evictIfIdle(sid);
    return quickjs.UNDEFINED;
}

fn jsSessionOutline(ctx: Context, _: Value, args: []const Value) Value {
    const rt = runtimeArg(ctx, args) orelse return ctx.newString("null");
    var aw: std.Io.Writer.Allocating = .init(Host.fromContext(ctx).engine.gpa);
    defer aw.deinit();
    project.writeOutline(&aw.writer, rt) catch return ctx.newString("null");
    return ctx.newString(aw.written());
}

/// The live activity of one open session as JSON, or "null" for a session no pane opened.
fn jsSessionActivity(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.newString("null");
    const rt = runtimeArg(ctx, args) orelse return ctx.newString("null");
    var arena_state: std.heap.ArenaAllocator = .init(engine.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const activity = session_events.residentActivity(&runtime.engine, arena, rt) catch return ctx.newString("null");
    const text = std.json.Stringify.valueAlloc(arena, activity, .{ .emit_null_optional_fields = false }) catch return ctx.newString("null");
    return ctx.newString(text);
}

fn jsSessionParts(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const rt = runtimeArg(ctx, args) orelse return ctx.newString("[]");
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString("[]");
    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    project.writeMessageParts(&aw.writer, rt, mid, null, null) catch return ctx.newString("[]");
    return ctx.newString(aw.written());
}

/// One part of a message as a one-element JSON array, or `[]` when the message or the part is gone.
fn jsSessionPart(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const rt = runtimeArg(ctx, args) orelse return ctx.newString("[]");
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString("[]");
    const pid = u64Arg(ctx, args, 2) orelse return ctx.newString("[]");
    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    const generation = u64Arg(ctx, args, 3);
    const offset = if (u64Arg(ctx, args, 4)) |n| std.math.cast(usize, n) else null;
    const cursor: ?project.TextCursor = if (generation != null and offset != null) .{ .generation = generation.?, .offset = offset.? } else null;
    project.writeMessageParts(&aw.writer, rt, mid, pid, cursor) catch return ctx.newString("[]");
    return ctx.newString(aw.written());
}

/// One page of a message's whole text: `{"text":...,"next":N|null,"bytes":T}`. The cost follows the page, not the message.
fn jsSessionText(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const empty = "{\"text\":\"\",\"next\":null,\"bytes\":0}";
    const rt = runtimeArg(ctx, args) orelse return ctx.newString(empty);
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString(empty);
    const offset: usize = @intCast(u64Arg(ctx, args, 2) orelse 0);
    const want = paging.pageLimit(u64Arg(ctx, args, 3));

    var raw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer raw.deinit();
    const page = paging.textPage(rt, mid, offset, want, &raw) orelse return ctx.newString(empty);

    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    writePage(&aw.writer, page.text, page.next, page.total) catch return ctx.newString(empty);
    return ctx.newString(aw.written());
}

/// One page of one field of a part: `{"text":...,"next":N|null}`. `field` is the address a `cut` entry names.
fn jsPartText(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const empty = "{\"text\":\"\",\"next\":null}";
    if (args.len <= 3) return ctx.newString(empty);
    const field = module.string(ctx, args[3]) orelse return ctx.newString(empty);
    defer ctx.freeCString(field.ptr);
    const rt = runtimeArg(ctx, args) orelse return ctx.newString(empty);
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString(empty);
    const part_id = u64Arg(ctx, args, 2) orelse return ctx.newString(empty);
    const offset = u64Arg(ctx, args, 4) orelse 0;
    const want = paging.pageLimit(u64Arg(ctx, args, 5));

    const text = paging.partTextOf(rt, mid, part_id, field) orelse return ctx.newString(empty);
    const page = paging.fieldPage(text, offset, want) orelse return ctx.newString(empty);

    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    writePage(&aw.writer, page.text, page.next, null) catch return ctx.newString(empty);
    return ctx.newString(aw.written());
}

fn writePage(w: *std.Io.Writer, text: []const u8, next: ?usize, bytes: ?usize) !void {
    try w.writeAll("{\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    if (next) |offset| try w.print(",\"next\":{d}", .{offset}) else try w.writeAll(",\"next\":null");
    if (bytes) |total| try w.print(",\"bytes\":{d}", .{total});
    try w.writeByte('}');
}

/// Run one command on the owner and answer a settled Promise, so a caller reads every outcome one way.
fn jsRequest(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (host.phase != .open) return pending.rejected(ctx, "the host is closed");
    const runtime = host.engine.runtime orelse return pending.rejected(ctx, "the engine is not ready");
    if (args.len < 2) return pending.rejected(ctx, "a call needs a method and parameters");
    const method = module.string(ctx, args[0]) orelse return pending.rejected(ctx, "the method must be a string");
    defer ctx.freeCString(method.ptr);
    const params = module.string(ctx, args[1]) orelse return pending.rejected(ctx, "the parameters must be JSON");
    defer ctx.freeCString(params.ptr);

    var arena: std.heap.ArenaAllocator = .init(host.gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const failure = engine_call.call(runtime, arena.allocator(), method, params, &out.writer) catch
        return pending.rejected(ctx, "internal error");
    if (failure) |refused| return pending.rejectedWith(ctx, .{ .message = refused.message, .code = @tagName(refused.code) });
    return pending.resolved(ctx, ctx.newString(out.written()));
}

/// Undefined preserves a field; null clears its configured value.
fn jsSetPromptConfig(ctx: Context, _: Value, args: []const Value) Value {
    const runtime = Host.fromContext(ctx).engine.runtime orelse return ctx.throwPlainError("the engine is not ready");
    if (args.len != 2) return ctx.throwTypeError("prompt config expects two fields");
    var prompts = [_]?[]const u8{ runtime.engine.default_system_prompt, runtime.engine.child_instructions };
    var strings: [2]?[:0]const u8 = .{ null, null };
    defer for (strings) |text| {
        if (text) |value| ctx.freeCString(value.ptr);
    };
    for (args, 0..) |arg, index| {
        if (ctx.isUndefined(arg)) continue;
        if (ctx.isNull(arg)) {
            prompts[index] = null;
            continue;
        }
        if (!ctx.isString(arg)) return ctx.throwTypeError("prompt fields must be strings, null, or undefined");
        const text = ctx.toCStringLen(arg) catch return module.throwPending(ctx);
        strings[index] = text;
        if (text.len > max_system_prompt_bytes) return ctx.throwTypeError("prompt exceeds the protocol string limit");
        if (!std.unicode.utf8ValidateSlice(text)) return ctx.throwTypeError("prompt must contain valid Unicode");
        prompts[index] = text;
    }
    runtime.engine.setPromptConfig(prompts[0], prompts[1]) catch unreachable;
    return quickjs.UNDEFINED;
}

const app_fixture = @import("../../app/fixture.zig");
const testing = std.testing;

test "view integers stay within the protocol safe integer range" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const max = proto.meta.constants.MAX_WIRE_INTEGER;
    const accepted = host.ctx.newFloat64(@floatFromInt(max));
    defer host.ctx.freeValue(accepted);
    try testing.expectEqual(max, u64Arg(host.ctx, &.{accepted}, 0).?);
    const rejected = host.ctx.newFloat64(@floatFromInt(max + 1));
    defer host.ctx.freeValue(rejected);
    try testing.expectEqual(null, u64Arg(host.ctx, &.{rejected}, 0));
}

test "a request reaches a command and answers with its result" {
    const ai = @import("ai");

    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    var canned = ai.testing.CannedTransport{ .bytes = ai.testing.canned_reply };
    var blobs = testing.tmpDir(.{});
    defer blobs.cleanup();
    var blob_dir: [std.fs.max_path_bytes]u8 = undefined;
    var runtime: app.App = undefined;
    try app_fixture.init(&runtime, testing.allocator, rt.io(), blob_dir[0..try blobs.dir.realPath(testing.io, &blob_dir)], execution.testContext(&env), canned.transport());
    defer runtime.deinit();
    try app_fixture.installModel(&runtime);

    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);

    // With no engine, a view read answers its empty projection and a request refuses.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\globalThis.detached = 0;
        \\native.request("catalog.list", "{}").catch(() => { globalThis.detached = 1; });
    , "detached.js");
    try support.pumpUntilIdle(host);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.detached"));

    // With the engine attached, the same call reaches `commands.catalogList`.
    host.engine.attach(&runtime);
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\native.request("catalog.list", "{}").then((text) => {
        \\  const r = JSON.parse(text);
        \\  globalThis.ok = r && Array.isArray(r.models) ? 1 : 0;
        \\});
    , "attached.js");
    try support.pumpUntilIdle(host);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ok"));

    // A command with real parameters must decode them, not fall back to an empty object.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\native.request("session.create", JSON.stringify({ workspace_path: "/tmp/yuke-probe", model: "test/model" })).then((text) => {
        \\  const r = JSON.parse(text);
        \\  globalThis.created = r && r.session ? 1 : 0;
        \\  globalThis.sid = r && r.session ? r.session.id : "";
        \\  native.sessionOpen(globalThis.sid);
        \\});
    , "create.js");
    try support.pumpUntilIdle(host);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.created"));

    // The client shape of an input must decode. A wrong shape refuses every message a person sends.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\globalThis.sent = 0;
        \\client.sessionSendInput(globalThis.sid, client.textContent("probe")).then(() => { globalThis.sent = 1; }, () => { globalThis.sent = 2; });
    , "send.js");
    try support.pumpUntilIdle(host);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.sent"));

    // The text a person typed must come back; the client reads the complete text through bounded native pages.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\const o = client.sessionOutline(globalThis.sid);
        \\const first = o && o.messages.length ? o.messages[0].id : 0;
        \\globalThis.text = first ? client.sessionWholeText(globalThis.sid, first) : "";
        \\globalThis.len = globalThis.text.length;
    , "text.js");
    try testing.expectEqual(@as(i32, 5), try host.evalInt("globalThis.len")); // "probe"

    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\let coerced = 0;
        \\const field = { toString() { coerced++; native.sessionClose(globalThis.sid); return "text"; } };
        \\const page = JSON.parse(native.partText(globalThis.sid, 1, 1, field));
        \\const id = { toString() { coerced++; return globalThis.sid; } };
        \\globalThis.safeArgs = page.text === "" && page.next === null && !native.sessionOpen(id) && coerced === 0;
        \\globalThis.stillOpen = native.sessionOutline(globalThis.sid) !== "null";
    , "arguments.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.safeArgs && globalThis.stillOpen"));

    // A refusal reaches JavaScript as an error that names its wire code.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\globalThis.code = "";
        \\native.request("session.config", JSON.stringify({ session_id: "00".repeat(16), config_rev: 1 })).catch((e) => {
        \\  globalThis.isUnknown = e.code === "unknown_session" ? 1 : 0;
        \\});
    , "refuse.js");
    try support.pumpUntilIdle(host);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.isUnknown"));
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\native.sessionClose(globalThis.sid);
    , "close.js");
    host.engine.detach();
}

const support = @import("../tests/support.zig");

test "process activity uses live engine state and scoped coalesced notifications" {
    const Tree = @import("../bench/agents.zig");
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const host = support.createHostWith(rt.io(), "");
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\import { Context, Scope } from "yuke:ext";
        \\globalThis.client = client;
        \\globalThis.observer = new Context(new Scope("activity-test"), "activity-test");
        \\globalThis.seen = [];
        \\observer.on("engine.activity.changed", (...args) => {
        \\  if (args.length !== 0) throw new Error("activity carries no payload");
        \\  seen.push(client.isBusy());
        \\});
    , "activity.js");
    try testing.expectEqual(@as(i32, 0), try host.evalInt("client.isBusy()"));
    const tree = try Tree.create(host, 2, .wide);
    defer tree.destroy();
    defer host.engine.detach();
    try host.pump();
    try testing.expectEqual(@as(i32, 0), try host.evalInt("seen.length"));

    // A child has no pane, but its prepared run already belongs to this process.
    const sid = SessionId.bytes(std.mem.toBytes(@as(u128, 3)));
    const resident = tree.app.engine.sessions.get(sid).?;
    var prepared = try domain_session.RunSlot.prepare(host.gpa, "bench/model", "", "", null);
    const slot = prepared.bind(.{
        .input_id = 1,
        .started = .{ .session_id = sid, .seq = 1, .run_id = 1, .kind = .turn, .config_rev = 0, .started_at_ms = 1 },
    }, .bytes(std.mem.toBytes(@as(u128, 1))), .{ .root = .bytes(std.mem.toBytes(@as(u128, 1))), .depth = 1 });
    defer slot.destroy();
    resident.active_run = slot;
    defer resident.active_run = null;
    try testing.expectEqual(@as(u32, 0), resident.pins);
    try testing.expectEqual(@as(i32, 1), try host.evalInt("client.isBusy()"));
    tree.app.engine.sinks.emit(.{ .method = .@"run.started", .params = .{ .run_started_data = slot.handle.started } });
    try testing.expect(host.engine.hasPending());
    try host.pump();
    try testing.expectEqual(@as(i32, 1), try host.evalInt("seen.length === 1 && seen[0]"));

    tree.app.engine.beginContinuation();
    resident.active_run = null;
    try host.pump();
    try testing.expectEqual(@as(i32, 1), try host.evalInt("client.isBusy() && seen.length === 1"));
    tree.app.engine.endContinuation();
    try testing.expectEqual(@as(i32, 0), try host.evalInt("client.isBusy()"));
    try testing.expect(host.engine.hasPending());
    try host.pump();
    try testing.expectEqual(@as(i32, 1), try host.evalInt("seen.length === 2 && seen[1] === false"));

    tree.app.engine.beginContinuation();
    tree.app.engine.endContinuation();
    try host.pump();
    try testing.expectEqual(@as(i32, 2), try host.evalInt("seen.length"));
    tree.app.engine.beginContinuation();
    try host.pump();
    host.engine.detach();
    try host.pump();
    try testing.expectEqual(@as(i32, 1), try host.evalInt("!client.isBusy() && seen.length === 4 && seen[3] === false"));
    host.engine.attach(&tree.app);
    try host.pump();
    try host.evalModule("observer.scope.dispose();", "dispose.js");
    tree.app.engine.endContinuation();
    try host.pump();
    try testing.expectEqual(@as(i32, 5), try host.evalInt("seen.length"));
}

test {
    _ = digest;
    _ = paging;
    _ = project;
}

fn jsSetAgentLimits(ctx: Context, _: Value, args: []const Value) Value {
    const runtime = Host.fromContext(ctx).engine.runtime orelse return quickjs.UNDEFINED;
    const max_concurrent = if (args.len > 0) module.integer(ctx, args[0], 1, std.math.maxInt(u32)) else null;
    const max_depth = if (args.len > 1) module.integer(ctx, args[1], 1, std.math.maxInt(u32)) else null;
    runtime.engine.setAgentLimits(
        @intCast(max_concurrent orelse return ctx.throwTypeError("the maximum concurrent agents must be a positive 32-bit integer")),
        @intCast(max_depth orelse return ctx.throwTypeError("the maximum agent depth must be a positive 32-bit integer")),
    ) catch return ctx.throwPlainError("the agent scheduler could not start");
    return quickjs.UNDEFINED;
}
