//! `yuke -p`: one turn without a view. The reply goes to stdout and the run outcome picks the status.

const std = @import("std");
const execution = @import("../execution.zig");
const zio = @import("zio");
const proto = @import("proto");
const cli = @import("../cli.zig");
const call = @import("call.zig");
const input_gate = @import("input_gate.zig");
const commands = @import("../engine/commands.zig");
const Engine = @import("../engine/Engine.zig");
const extensions_mod = @import("../js/extensions.zig");
const tools = @import("../js/tools.zig");
const Extensions = extensions_mod.Extensions;

/// Boot the headless graph with an answerer that denies every question.
pub const boot =
    \\import { plugins } from "yuke:ext";
    \\import { printInteractionPlugin } from "yuke:interaction";
    \\plugins.use(printInteractionPlugin);
;

/// The status of a run the user stopped, as a shell reports a SIGINT.
const status_interrupted: u8 = 130;
const max_prompt_bytes: usize = @intCast(proto.meta.limits.max_message_string_bytes);

/// Run one turn over `extensions` and answer the exit status. `cwd` is the canonical working directory.
pub fn run(gpa: std.mem.Allocator, io: std.Io, extensions: *Extensions, cwd: []const u8, opts: cli.Print) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Use a streaming writer, because a terminal does not support positional writes.
    const out_buf = try arena.alloc(u8, 1 << 16);
    var out = std.Io.File.stdout().writerStreaming(io, out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);

    // A broken index.js is a warning, as in the RPC frontend. The run goes on without its plugins.
    if (extensions.user_entry_fault) {
        try err.interface.print("yuke -p: JavaScript fault in index.js: {s}\n", .{extensions.host.faultText()});
        try err.interface.flush();
        extensions.host.clearFault();
    }
    const prompt = (try readPrompt(io, arena, &err.interface, opts.prompt)) orelse return 2;
    const status = try runWith(extensions, arena, &out.interface, &err.interface, cwd, prompt, opts);
    try out.interface.flush();
    return status;
}

/// One diagnostic line on stderr, flushed at once so it lands before the next log line.
fn fail(err: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    try err.print("yuke -p: " ++ format ++ "\n", args);
    try err.flush();
}

/// The prompt from argv, or from stdin when it is not a terminal. Null means a reported refusal.
fn readPrompt(io: std.Io, arena: std.mem.Allocator, err: *std.Io.Writer, given: ?[]const u8) !?[]const u8 {
    const text = given orelse blk: {
        const stdin = std.Io.File.stdin();
        if (stdin.isTty(io) catch false) {
            try fail(err, "no prompt; pass one or pipe it on stdin", .{});
            return null;
        }
        var buf: [4096]u8 = undefined;
        var reader = stdin.readerStreaming(io, &buf);
        // Two bytes over the bound leave room for a line ending, which the trim below removes.
        break :blk reader.interface.allocRemaining(arena, .limited(max_prompt_bytes + 2)) catch |e| switch (e) {
            error.StreamTooLong => {
                try fail(err, "the prompt exceeds {d} bytes", .{max_prompt_bytes});
                return null;
            },
            else => return e,
        };
    };
    const prompt = std.mem.trimEnd(u8, text, "\r\n");
    if (prompt.len > max_prompt_bytes) {
        try fail(err, "the prompt exceeds {d} bytes", .{max_prompt_bytes});
        return null;
    }
    if (prompt.len == 0) {
        try fail(err, "the prompt is empty", .{});
        return null;
    }
    return prompt;
}

/// The chosen session and the model it runs. `model` borrows the arena.
const Pick = struct { id: proto.ids.SessionId, model: []const u8, input: ?proto.session.SessionSendInputResult = null };

fn runWith(extensions: *Extensions, arena: std.mem.Allocator, w: *std.Io.Writer, err: *std.Io.Writer, cwd: []const u8, prompt: []const u8, opts: cli.Print) !u8 {
    std.debug.assert(prompt.len != 0 and prompt.len <= max_prompt_bytes);
    const engine = &extensions.app.engine;
    var waiter: Waiter = .{ .arena = arena, .session_id = null, .wake = &extensions.host.wake, .io = extensions.host.io, .err = if (opts.json) null else err };
    engine.sinks.add(.{ .ctx = @ptrCast(&waiter), .on_event = Waiter.onEvent });
    defer engine.sinks.remove(@ptrCast(&waiter));

    const pick = (try pickSession(extensions, arena, err, cwd, prompt, opts)) orelse return 1;
    waiter.bind(pick.id);
    const sent: call.Answer(proto.session.SessionSendInputResult) = if (pick.input) |input| .{ .ok = input } else try gated(extensions, arena, proto.session.SessionSendInputParams{
        .session_id = pick.id,
        .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = prompt } }} } },
    });
    const started = switch (sent) {
        .failure => |f| {
            try fail(err, "{t}: {s}", .{ f.code, f.message });
            return 1;
        },
        .ok => |result| switch (result) {
            .started => |s| s,
            // Input that waits behind a queue has no run of its own to wait on, so it leaves the queue.
            .queued => |q| {
                _ = try commands.sessionCancelInput(engine, arena, .{ .session_id = pick.id, .input_id = q.input_id });
                try fail(err, "the session already holds queued input", .{});
                return 1;
            },
        },
    };
    try pumpUntil(extensions, RunWait{ .waiter = &waiter, .run_id = started.run_id }, RunWait.done);

    const done = waiter.doneOf(started.run_id).?;
    const status: u8 = switch (done.outcome) {
        .turn => 0,
        .failed => |f| blk: {
            try fail(err, "{t}: {s}", .{ f.code, f.message });
            break :blk 1;
        },
        .canceled => status_interrupted,
        .compacted, .skipped => unreachable, // A turn run never compacts.
    };
    if (opts.json) {
        try writeReport(arena, w, &waiter, pick, done.*);
        return status;
    }
    if (waiter.lastOf(started.run_id)) |last| {
        for (last.content) |part| switch (part) {
            .text => |t| try w.print("{s}\n", .{t.text}),
            else => {},
        };
    }
    return status;
}

/// Resolve the target: a fresh session on `cwd`, the newest one there, or the one named by id.
fn pickSession(extensions: *Extensions, arena: std.mem.Allocator, err: *std.Io.Writer, cwd: []const u8, prompt: []const u8, opts: cli.Print) !?Pick {
    const engine = &extensions.app.engine;
    switch (opts.target) {
        .new => {
            const model = opts.model orelse if (try newest(engine, arena, null)) |session| session.model else {
                try fail(err, "no model; pass --model <provider/model>", .{});
                return null;
            };
            const params: proto.misc.CreateSession = .{ .workspace_path = cwd, .model = model, .reasoning = opts.reasoning, .initial_input = .{ .content = .{ .content = &.{.{ .text = .{ .text = prompt } }} } } };
            const created = switch (try gated(extensions, arena, params)) {
                .ok => |result| result,
                .failure => |f| {
                    try fail(err, "{t}: {s}", .{ f.code, f.message });
                    return null;
                },
            };
            return .{ .id = created.session.id, .model = created.session.model, .input = created.input };
        },
        .@"continue" => {
            const id = if (try newest(engine, arena, cwd)) |session| session.id else {
                try fail(err, "no session in this directory", .{});
                return null;
            };
            return try configured(engine, arena, err, id);
        },
        .session => |text| {
            std.debug.assert(proto.ids.SessionId.validText(text)); // The parser accepts only a wire id.
            var id: proto.ids.SessionId = undefined;
            _ = std.fmt.hexToBytes(&id.raw, text) catch unreachable;
            return try configured(engine, arena, err, id);
        },
    }
}

/// The session and the model its config names, or null for an unknown id.
fn configured(engine: *Engine, arena: std.mem.Allocator, err: *std.Io.Writer, id: proto.ids.SessionId) !?Pick {
    const config = commands.sessionConfig(engine, arena, .{ .session_id = id }) catch |e| switch (e) {
        error.UnknownSession => {
            try fail(err, "unknown session", .{});
            return null;
        },
        else => return e,
    };
    return .{ .id = id, .model = config.config.model };
}

/// Return the newest session, with an optional workspace filter.
fn newest(engine: *Engine, arena: std.mem.Allocator, cwd: ?[]const u8) !?proto.misc.Session {
    const listed = try commands.sessionList(engine, arena, .{ .limit = proto.meta.limits.max_page_size });
    var best: ?proto.misc.Session = null;
    for (listed.items) |item| {
        if (cwd) |root| {
            if (!std.mem.eql(u8, item.session.root, root)) continue;
        } else if (item.session.model.len == 0) continue;
        if (best == null or item.session.updated_at_ms > best.?.updated_at_ms) best = item.session;
    }
    return best;
}

/// Fold `input.before` on the owner when a handler waits, then run the command. The RPC frontend holds its inputs through the same gate.
fn gated(extensions: *Extensions, arena: std.mem.Allocator, params: anytype) !input_gate.AnswerOf(@TypeOf(params)) {
    const record = input_gate.submit(extensions.host, arena, params);
    defer if (record) |held| held.finish();
    if (record) |held| try pumpUntil(extensions, held, callSettled);
    return input_gate.finish(extensions.app, extensions.host, arena, params, record);
}

/// Pump until `done(context)` holds. Tools and hooks run on the owner; a script fault is logged, and the run goes on without the handler.
fn pumpUntil(extensions: *Extensions, context: anytype, comptime done: fn (@TypeOf(context)) bool) !void {
    const host = extensions.host;
    while (true) return host.pumpUntil(null, context, done) catch |err| switch (err) {
        error.JavaScriptFault => {
            std.log.warn("yuke -p: JavaScript fault: {s}", .{host.faultText()});
            host.clearFault();
            continue;
        },
        else => |e| return e,
    };
}

fn callSettled(record: *tools.Call) bool {
    return record.state == .settled;
}

const RunWait = struct {
    waiter: *const Waiter,
    run_id: proto.ids.RunId,

    fn done(self: RunWait) bool {
        return self.waiter.doneOf(self.run_id) != null;
    }
};

/// The events of one session, copied out of the emitter's arena, and the wake of the owner loop.
const Waiter = struct {
    arena: std.mem.Allocator,
    session_id: ?proto.ids.SessionId,
    buffered: std.ArrayList(proto.rpc.Notification) = .empty,
    wake: *std.Io.Event,
    io: std.Io,
    /// Where a notice goes as it comes. Null keeps the notices for the JSON report.
    err: ?*std.Io.Writer,
    messages: std.ArrayList(proto.message.AssistantMessage) = .empty,
    dones: std.ArrayList(proto.run.RunDoneData) = .empty,
    notices: std.ArrayList(proto.misc.Notice) = .empty,

    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *Waiter = @ptrCast(@alignCast(ctx));
        if (self.session_id == null and note.method != .notice) {
            if (note.method == .@"message.committed" or note.method == .@"run.done") self.buffered.append(self.arena, proto.clone.dupe(self.arena, note) catch unreachable) catch unreachable;
            return;
        }
        switch (note.params) {
            .message_committed_data => |d| {
                if (!self.mine(d.session_id)) return;
                const assistant = switch (d.message) {
                    .assistant => |m| m,
                    else => return,
                };
                self.messages.append(self.arena, proto.clone.dupe(self.arena, assistant) catch unreachable) catch unreachable;
            },
            .run_done_data => |d| {
                if (!self.mine(d.session_id)) return;
                self.dones.append(self.arena, proto.clone.dupe(self.arena, d) catch unreachable) catch unreachable;
            },
            .notice => |n| self.noteNotice(n),
            else => return,
        }
        self.wake.set(self.io);
    }

    /// A JSON report carries the notices. A plain run shows them on stderr as they come.
    fn noteNotice(self: *Waiter, n: proto.misc.Notice) void {
        const err = self.err orelse {
            self.notices.append(self.arena, proto.clone.dupe(self.arena, n) catch unreachable) catch unreachable;
            return;
        };
        // A notice is advice. A failed write drops it and the run goes on.
        err.print("{s} · {s}: {s}\n", .{ n.source, @tagName(n.level), n.message }) catch return;
        err.flush() catch {};
    }

    fn bind(self: *Waiter, id: proto.ids.SessionId) void {
        std.debug.assert(self.session_id == null);
        self.session_id = id;
        for (self.buffered.items) |note| onEvent(self, note);
        self.buffered.clearRetainingCapacity();
    }

    fn mine(self: *const Waiter, id: proto.ids.SessionId) bool {
        return std.mem.eql(u8, &id.raw, &self.session_id.?.raw);
    }

    fn doneOf(self: *const Waiter, run_id: proto.ids.RunId) ?*const proto.run.RunDoneData {
        for (self.dones.items) |*d| if (d.run_id == run_id) return d;
        return null;
    }

    /// The last assistant message of the run, which holds the reply.
    fn lastOf(self: *const Waiter, run_id: proto.ids.RunId) ?*const proto.message.AssistantMessage {
        var i = self.messages.items.len;
        while (i > 0) : (i -= 1) if (self.messages.items[i - 1].run_id == run_id) return &self.messages.items[i - 1];
        return null;
    }
};

/// The one object `--json` prints. `outcome` and `messages` are the wire types.
const Report = struct {
    session_id: proto.ids.SessionId,
    run_id: proto.ids.RunId,
    model: []const u8,
    text: []const u8,
    outcome: proto.run.RunOutcome,
    usage: proto.message.TokenUsage,
    messages: []const proto.message.AssistantMessage,
    notices: []const proto.misc.Notice,
};

fn writeReport(arena: std.mem.Allocator, w: *std.Io.Writer, waiter: *const Waiter, pick: Pick, done: proto.run.RunDoneData) !void {
    var messages: std.ArrayList(proto.message.AssistantMessage) = .empty;
    var usage: proto.message.TokenUsage = .zero;
    for (waiter.messages.items) |m| {
        if (m.run_id != done.run_id) continue;
        try messages.append(arena, m);
        const t = m.tokens orelse continue;
        usage.input += t.input;
        usage.output += t.output;
        usage.reasoning += t.reasoning;
        usage.cache_read += t.cache_read;
        usage.cache_write += t.cache_write;
    }
    var text: std.Io.Writer.Allocating = .init(arena);
    if (waiter.lastOf(done.run_id)) |last| {
        for (last.content) |part| switch (part) {
            .text => |t| {
                if (text.written().len != 0) try text.writer.writeByte('\n');
                try text.writer.writeAll(t.text);
            },
            else => {},
        };
    }
    const report: Report = .{
        .session_id = pick.id,
        .run_id = done.run_id,
        .model = pick.model,
        .text = text.written(),
        .outcome = done.outcome,
        .usage = usage,
        .messages = messages.items,
        .notices = waiter.notices.items,
    };
    try std.json.Stringify.value(report, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

// ---------------------------------------------------------------- tests

const app_fixture = @import("fixture.zig");
const testing = std.testing;
const ai = @import("ai");

const App = @import("app.zig").App;

/// One headless print host over a canned provider, with a key in the environment so a model resolves.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    reactor: *zio.Runtime,
    env: std.process.Environ.Map,
    canned: ai.testing.CannedTransport,
    app: App,
    extensions: Extensions,

    fn init(self: *Fixture, entry: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = extensions_mod.user_entry, .data = entry });
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        self.reactor = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
        self.env = .init(testing.allocator);
        try self.env.put("ANTHROPIC_API_KEY", "sk-test");
        self.canned = .{ .bytes = ai.testing.canned_reply };
        // One context, so a split between the two owners is a test failure and not a silent drift.
        const context = execution.testContext(&self.env);
        try app_fixture.init(&self.app, testing.allocator, self.reactor.io(), self.root, self.canned.transport(), context);
        try self.app.store.rebuild();
        try self.extensions.init(testing.allocator, self.reactor.io(), &self.app, .{
            .host = .{ .cwd = self.root, .execution = context },
            .boot = boot,
            .config_dir = self.root,
        });
        try testing.expect(!self.extensions.user_entry_fault);
    }

    fn deinit(self: *Fixture) void {
        self.extensions.deinit();
        self.app.deinit();
        self.env.deinit();
        self.reactor.deinit();
        self.tmp.cleanup();
    }

    /// Run one print turn and answer the status and both streams, which borrow `arena`.
    fn print(self: *Fixture, arena: std.mem.Allocator, prompt: []const u8, opts: cli.Print) !struct { status: u8, out: []const u8, err: []const u8 } {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        const status = try runWith(&self.extensions, arena, &out.writer, &err.writer, self.root, prompt, opts);
        return .{ .status = status, .out = out.written(), .err = err.written() };
    }
};

const test_model = "anthropic/claude-sonnet-4-5";

test "a print run answers the reply text, then continues the same session as JSON" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try f.print(arena, "hello", .{ .model = test_model });
    try testing.expectEqual(@as(u8, 0), plain.status);
    try testing.expectEqualStrings("Hello from the mock provider.\n", plain.out);
    try testing.expectEqualStrings("", plain.err);

    // The run named the model, so the next run in this directory needs no `--model`.
    const again = try f.print(arena, "again", .{ .json = true, .target = .@"continue" });
    try testing.expectEqual(@as(u8, 0), again.status);
    const report = try std.json.parseFromSliceLeaky(Report, arena, again.out, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(test_model, report.model);
    try testing.expectEqualStrings("Hello from the mock provider.", report.text);
    try testing.expect(report.outcome == .turn);
    try testing.expectEqual(@as(usize, 1), report.messages.len);
    try testing.expectEqual(@as(u64, 8), report.usage.output);

    // A session that never existed refuses before a send.
    const unknown = try f.print(arena, "x", .{ .target = .{ .session = "00000000000000000000000000000000" } });
    try testing.expectEqual(@as(u8, 1), unknown.status);
    try testing.expectEqualStrings("", unknown.out);
    try testing.expectEqualStrings("yuke -p: unknown session\n", unknown.err);
}

test "a print run refuses a model the catalog cannot resolve before it creates a session" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const none = try f.print(arena, "hello", .{});
    try testing.expectEqual(@as(u8, 1), none.status); // No session names a model yet.
    try testing.expectEqualStrings("yuke -p: no model; pass --model <provider/model>\n", none.err);
    try testing.expectEqualStrings("", none.out);

    const bad = try f.print(arena, "hello", .{ .model = "nope/nothing", .json = true });
    try testing.expectEqual(@as(u8, 1), bad.status);
    try testing.expectEqualStrings("", bad.out); // The create refuses, so no run reports an outcome.
    try testing.expect(std.mem.startsWith(u8, bad.err, "yuke -p: unsupported_model: "));
}

test "a print run denies a plugin question and reports it as a notice" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "ask", apply(ctx) {
        \\  ctx.hook("input.before", async () => {
        \\    const ok = await ctx.interaction.confirm("allow", "send it?");
        \\    return ok === false ? { block: "denied" } : undefined;
        \\  });
        \\} });
    );
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The hook holds the input, the answerer says no, and the gate refuses the send.
    const refused = try f.print(arena, "hello", .{ .model = test_model });
    try testing.expectEqual(@as(u8, 1), refused.status);
    try testing.expectEqualStrings("", refused.out);
    try testing.expectEqualStrings("ask · warn: denied: allow\nyuke -p: bad_request: an extension stopped the input\n", refused.err);
}
