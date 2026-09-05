//! The native `yuke:engine` module: the JavaScript seam onto the one in-process engine.
//! There is no transport and no replica. A view reads the engine's own session projection.
//!
//! Two rules hold this seam together. An event never re-enters JavaScript from an engine task;
//! the sink marks a session dirty and `drain` delivers it on the owner. And a text read is paged,
//! so one call copies a bounded number of bytes however large the message is.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const proto = @import("proto");
const host_mod = @import("../host.zig");
const module = @import("module.zig");
const digest = @import("engine/digest.zig");
const paging = @import("engine/paging.zig");
const project = @import("engine/project.zig");
const app = @import("../../app/app.zig");
const App = app.App;
const engine_call = @import("../../app/call.zig");
const turn = @import("../../engine/turn.zig");
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
        .{ .name = "setDefaultSystemPrompt", .arity = 1, .call = jsSetDefaultSystemPrompt },
        .{ .name = "setEventSink", .arity = 1, .call = jsSetEventSink },
        .{ .name = "factNames", .arity = 0, .call = jsFactNames },
        .{ .name = "memoryUsage", .arity = 0, .call = jsMemoryUsage },
        .{ .name = "request", .arity = 2, .call = jsRequest },
        .{ .name = "sessionOpen", .arity = 1, .call = jsSessionOpen },
        .{ .name = "sessionClose", .arity = 1, .call = jsSessionClose },
        .{ .name = "sessionOutline", .arity = 1, .call = jsSessionOutline },
        .{ .name = "sessionParts", .arity = 2, .call = jsSessionParts },
        .{ .name = "sessionPart", .arity = 3, .call = jsSessionPart },
        .{ .name = "sessionText", .arity = 4, .call = jsSessionText },
        .{ .name = "partText", .arity = 6, .call = jsPartText },
    }, null);
}

// ---------------------------------------------------------------- javascript seam

fn sidArg(ctx: Context, args: []const Value, idx: usize) ?SessionId {
    if (args.len <= idx) return null;
    const text = ctx.toCStringLen(args[idx]) catch return null;
    defer ctx.freeCString(text.ptr);
    if (text.len != SessionId.byte_len * 2) return null;
    var raw: [SessionId.byte_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, text) catch return null;
    return SessionId.bytes(raw);
}

fn u64Arg(ctx: Context, args: []const Value, idx: usize) ?u64 {
    if (args.len <= idx) return null;
    return module.integer(ctx, args[idx], 0, std.math.maxInt(u64));
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
        ctx.setPropertyUint32(names, @intCast(i), ctx.newString(@tagName(fact))) catch {};
    }
    return built(ctx, names);
}

/// Answer a built value, or free it and throw once the QuickJS heap is full.
fn built(ctx: Context, value: Value) Value {
    if (!ctx.hasException()) return value;
    ctx.freeValue(value);
    return module.throwPending(ctx);
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
    return built(ctx, out);
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
    // The durable queue of this session restarts here, in the one process that looks at it.
    turn.resumeSession(&runtime.engine, rt) catch |err| {
        std.log.warn("cannot resume session: {t}", .{err});
    };
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

fn jsSessionParts(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const rt = runtimeArg(ctx, args) orelse return ctx.newString("[]");
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString("[]");
    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    project.writeMessageParts(&aw.writer, rt, mid, null) catch return ctx.newString("[]");
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
    project.writeMessageParts(&aw.writer, rt, mid, pid) catch return ctx.newString("[]");
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
    aw.writer.writeAll("{\"text\":") catch return ctx.newString(empty);
    std.json.Stringify.encodeJsonString(page.text, .{}, &aw.writer) catch return ctx.newString(empty);
    if (page.next) |next|
        aw.writer.print(",\"next\":{d},\"bytes\":{d}}}", .{ next, page.total }) catch return ctx.newString(empty)
    else
        aw.writer.print(",\"next\":null,\"bytes\":{d}}}", .{page.total}) catch return ctx.newString(empty);
    return ctx.newString(aw.written());
}

/// One page of one field of a part: `{"text":...,"next":N|null}`. `field` is the address a `cut` entry names.
fn jsPartText(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const empty = "{\"text\":\"\",\"next\":null}";
    const rt = runtimeArg(ctx, args) orelse return ctx.newString(empty);
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString(empty);
    const part_id = u64Arg(ctx, args, 2) orelse return ctx.newString(empty);
    if (args.len <= 3) return ctx.newString(empty);
    const field = ctx.toCStringLen(args[3]) catch return ctx.newString(empty);
    defer ctx.freeCString(field.ptr);
    const offset = u64Arg(ctx, args, 4) orelse 0;
    const want = paging.pageLimit(u64Arg(ctx, args, 5));

    const text = paging.partTextOf(rt, mid, part_id, field) orelse return ctx.newString(empty);
    const page = paging.fieldPage(text, offset, want) orelse return ctx.newString(empty);

    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    aw.writer.writeAll("{\"text\":") catch return ctx.newString(empty);
    std.json.Stringify.encodeJsonString(page.text, .{}, &aw.writer) catch return ctx.newString(empty);
    if (page.next) |next|
        aw.writer.print(",\"next\":{d}}}", .{next}) catch return ctx.newString(empty)
    else
        aw.writer.writeAll(",\"next\":null}") catch return ctx.newString(empty);
    return ctx.newString(aw.written());
}

/// Run one command and answer with its result JSON, with no envelope. A refusal throws with its wire code.
fn jsRequest(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.throwPlainError("the engine is not ready");
    if (args.len < 2) return ctx.throwPlainError("a call needs a method and parameters");

    const method = ctx.toCStringLen(args[0]) catch return ctx.throwPlainError("the method must be a string");
    defer ctx.freeCString(method.ptr);
    const params = ctx.toCStringLen(args[1]) catch return ctx.throwPlainError("the parameters must be JSON");
    defer ctx.freeCString(params.ptr);

    var arena_state: std.heap.ArenaAllocator = .init(engine.gpa);
    defer arena_state.deinit();

    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();

    const failure = engine_call.call(runtime, arena_state.allocator(), method, params, &aw.writer) catch
        return ctx.throwPlainError("internal error");
    if (failure) |refused| return throwFailure(ctx, refused);
    return ctx.newString(aw.written());
}

/// Set the default prompt for sessions created without an explicit prompt.
fn jsSetDefaultSystemPrompt(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.throwPlainError("the engine is not ready");
    if (args.len < 1 or (!ctx.isString(args[0]) and !ctx.isNull(args[0])))
        return ctx.throwTypeError("the default system prompt must be a string or null");
    if (ctx.isNull(args[0])) {
        runtime.engine.setDefaultSystemPrompt(null) catch unreachable;
        return quickjs.UNDEFINED;
    }
    const prompt = ctx.toCStringLen(args[0]) catch return module.throwPending(ctx);
    defer ctx.freeCString(prompt.ptr);
    if (prompt.len > max_system_prompt_bytes)
        return ctx.throwTypeError("the default system prompt exceeds the protocol string limit");
    runtime.engine.setDefaultSystemPrompt(prompt) catch unreachable;
    return quickjs.UNDEFINED;
}

/// Raise a refusal as a JavaScript error that carries its wire code, so a view can branch on it.
fn throwFailure(ctx: Context, failure: engine_call.Failure) Value {
    const err = ctx.newError();
    module.set(ctx, err, "message", ctx.newString(failure.message));
    module.set(ctx, err, "code", ctx.newString(@tagName(failure.code)));
    if (ctx.hasException()) {
        ctx.freeValue(err);
        return module.throwPending(ctx);
    }
    return ctx.throw(err);
}

const testing = std.testing;

test "a request reaches a command and answers with its result" {
    const ai = @import("ai");
    const database = @import("../../store/store.zig");

    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    var canned = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };
    var runtime: app.App = undefined;
    try runtime.initTest(testing.allocator, rt.io(), try database.Database.openTest(), &env, canned.transport());
    defer runtime.logins.deinit();
    defer runtime.store.deinit();
    defer runtime.db.deinit();
    defer runtime.engine.close();

    const host = Host.create(testing.allocator);
    defer host.destroy();

    // With no engine, a view read answers its empty projection and a request refuses.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\let threw = 0;
        \\try { native.request("catalog.list", "{}"); } catch { threw = 1; }
        \\globalThis.detached = threw;
    , "detached.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.detached"));

    // With the engine attached, the same call reaches `commands.catalogList`.
    host.engine.attach(&runtime);
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\const r = JSON.parse(native.request("catalog.list", "{}"));
        \\globalThis.ok = r && Array.isArray(r.models) ? 1 : 0;
    , "attached.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ok"));

    // A command with real parameters must decode them, not fall back to an empty object.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\const r = JSON.parse(native.request("session.create", JSON.stringify({ workspace_path: "/tmp/yuke-probe" })));
        \\globalThis.created = r && r.session ? 1 : 0;
        \\globalThis.sid = r && r.session ? r.session.id : "";
    , "create.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.created"));

    // The client shape of an input must decode. A wrong shape refuses every message a person sends.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\globalThis.sent = 0;
        \\client.sessionSendInput(globalThis.sid, "probe").then(() => { globalThis.sent = 1; }, () => { globalThis.sent = 2; });
    , "send.js");
    try host.drainJobs();
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.sent"));

    // The text a person typed must come back. A default limit reads one page, never zero bytes.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\const o = client.sessionOutline(globalThis.sid);
        \\const first = o && o.messages.length ? o.messages[0].id : 0;
        \\globalThis.text = first ? client.sessionText(globalThis.sid, first) : "";
        \\globalThis.len = globalThis.text.length;
    , "text.js");
    try testing.expectEqual(@as(i32, 5), try host.evalInt("globalThis.len")); // "probe"

    // A refusal reaches JavaScript as an error that names its wire code.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\globalThis.code = "";
        \\try { native.request("session.config", JSON.stringify({ session_id: "00".repeat(16), config_rev: 1 })); }
        \\catch (e) { globalThis.code = e.code || ""; }
        \\globalThis.isUnknown = globalThis.code === "unknown_session" ? 1 : 0;
    , "refuse.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.isUnknown"));
    host.engine.detach();
}

test {
    _ = digest;
    _ = paging;
    _ = project;
}
