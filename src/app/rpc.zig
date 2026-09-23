//! The JSONL stdio transport queues input and events so only the QuickJS owner writes output.

const std = @import("std");
const proto = @import("proto");
const app = @import("app.zig");
const call = @import("call.zig");
const input_gate = @import("input_gate.zig");
const extensions_mod = @import("../js/extensions.zig");
const tools_table = @import("../js/tools.zig");
const Host = extensions_mod.Host;
const zio = @import("zio");

const App = app.App;

/// Boot the frontend-neutral modules for a headless JSONL process.
pub const boot =
    \\import { plugins } from "yuke:ext";
    \\import { rpcInteractionPlugin } from "yuke:interaction";
    \\plugins.use(rpcInteractionPlugin);
;

/// The stdout buffer. One event holds a whole message, so the buffer suits the largest of them.
const out_buffer_bytes: usize = 1 << 16;
/// The stdin buffer. It must hold one whole request line, and `send_input` carries a message body.
const in_buffer_bytes: usize = @intCast(proto.meta.limits.max_message_string_bytes + (1 << 16));
const queue_slots = 64;

/// A notification owns a private arena until the owner writes it.
const OwnedNotification = struct {
    arena: std.heap.ArenaAllocator,
    value: proto.rpc.Notification,

    fn create(gpa: std.mem.Allocator, value: proto.rpc.Notification) *OwnedNotification {
        const owned = gpa.create(OwnedNotification) catch unreachable;
        owned.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .value = undefined };
        owned.value = proto.clone.dupe(owned.arena.allocator(), value) catch unreachable;
        return owned;
    }

    fn destroy(self: *OwnedNotification, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// A bounded FIFO for notifications from engine sinks.
pub const NotificationQueue = struct {
    items: [queue_slots]?*OwnedNotification = .{null} ** queue_slots,
    head: usize = 0,
    len: usize = 0,

    fn append(self: *NotificationQueue, owned: *OwnedNotification) !void {
        std.debug.assert(self.head < queue_slots);
        std.debug.assert(self.len <= queue_slots);
        if (self.len == queue_slots) return error.Full;
        const slot = (self.head + self.len) % queue_slots;
        std.debug.assert(self.items[slot] == null);
        self.items[slot] = owned;
        self.len += 1;
    }

    fn pop(self: *NotificationQueue) ?*OwnedNotification {
        std.debug.assert(self.head < queue_slots);
        std.debug.assert(self.len <= queue_slots);
        if (self.len == 0) return null;
        const owned = self.items[self.head] orelse unreachable;
        self.items[self.head] = null;
        self.head = (self.head + 1) % queue_slots;
        self.len -= 1;
        if (self.len == 0) self.head = 0;
        return owned;
    }
};

/// One transport. The engine sink queues values, and the owner writes them.
pub const Rpc = struct {
    app: *App,
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    notifications: *NotificationQueue,
    host: *Host,
    /// The inputs the gate holds. Each one writes its answer after the owner settles its call.
    inputs: std.ArrayList(GatedInput) = .empty,
    fatal: bool = false,
    /// Set while a line goes out. Two writers would interleave one line inside another.
    writing: bool = false,

    /// Leave every held input and free the list. The owner sweeps the call records on its next pump.
    pub fn deinit(self: *Rpc) void {
        for (self.inputs.items) |*input| input.deinit();
        self.inputs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Hold a hooked content input until the owner folds its chain; return false when the request runs now.
    fn gate(self: *Rpc, request: Line) bool {
        if (!self.host.hooks.holds(.@"input.before")) return false;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        const a = arena.allocator();
        // A bad parameter object runs now, so the command path answers it.
        const input = inputOf(a, request) orelse {
            arena.deinit();
            return false;
        };
        if (self.inputs.items.len == queue_slots) {
            arena.deinit();
            self.flushNotifications();
            if (request.id) |id| self.writeFailure(id, .queue_full, "too many requests are pending") catch |err| self.failWrite(err);
            return true;
        }
        const submitted = switch (input) {
            inline else => |params| input_gate.submit(self.host, a, params),
        };
        const record = submitted orelse {
            arena.deinit();
            return false;
        };
        const id = if (request.id) |value| a.dupe(u8, value) catch unreachable else null;
        self.inputs.append(self.gpa, .{ .arena = arena, .id = id, .input = input, .call = record }) catch unreachable;
        return true;
    }

    /// Run and answer every held input whose chain settled. The owner is the only writer.
    pub fn drainInputs(self: *Rpc) void {
        var i: usize = 0;
        while (i < self.inputs.items.len) {
            if (self.inputs.items[i].call.state != .settled) {
                i += 1;
                continue;
            }
            var held = self.inputs.orderedRemove(i);
            defer held.deinit();
            self.answerHeld(&held);
            if (self.fatal) return;
        }
    }

    fn answerHeld(self: *Rpc, held: *GatedInput) void {
        const arena = held.arena.allocator();
        var body: std.Io.Writer.Allocating = .init(arena);
        const failure = switch (held.input) {
            inline else => |params| if (input_gate.finish(self.app, self.host, arena, params, held.call)) |answer|
                call.encode(answer, &body.writer) catch unreachable
            else |err| blk: {
                std.log.err("rpc: {t} failed: {t}", .{ held.input, err });
                break :blk call.Failure{ .code = .internal, .message = "the command failed" };
            },
        };
        self.respond(held.id, failure, body.written());
    }

    /// Write the events the command raised, then its answer. A request without an id gets no answer.
    fn respond(self: *Rpc, request_id: ?[]const u8, failure: ?call.Failure, body: []const u8) void {
        self.flushNotifications();
        if (self.fatal) return;
        const id = request_id orelse return;
        if (failure) |f| {
            self.writeFailure(id, f.code, f.message) catch |err| self.failWrite(err);
        } else {
            self.writeResult(id, body) catch |err| self.failWrite(err);
        }
    }

    /// Queue one engine event without entering the owner or waiting on stdout.
    pub fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *Rpc = @ptrCast(@alignCast(ctx));
        const owned = OwnedNotification.create(self.gpa, note);
        self.notifications.append(owned) catch {
            owned.destroy(self.gpa);
            self.fail("notification queue is full");
        };
    }

    /// Mark the stream fatal and wake the owner to stop with no silent event loss.
    fn fail(self: *Rpc, message: []const u8) void {
        if (!self.fatal) std.log.err("rpc: {s}", .{message});
        self.fatal = true;
        self.host.wake.set(self.host.io);
    }

    fn failWrite(self: *Rpc, err: anyerror) void {
        std.log.warn("rpc: stdout failed: {t}", .{err});
        self.fail("stdout failed while writing JSONL");
    }

    /// Write every notification queued before this owner turn.
    pub fn flushNotifications(self: *Rpc) void {
        while (self.notifications.len > 0) {
            // Remove the pointer before writeValue can yield and let a sink append again.
            const owned = self.notifications.pop() orelse unreachable;
            defer owned.destroy(self.gpa);
            self.writeValue(owned.value) catch |err| {
                std.log.warn("rpc: cannot write {t}: {t}", .{ owned.value.method, err });
                self.fail("stdout failed while writing a notification");
                return;
            };
        }
        // Mark the question sent before the write; a failed write is fatal.
        while (self.host.interactions.takeNext()) |request| {
            self.writeValue(proto.rpc.Notification{
                .method = .@"interaction.requested",
                .params = .{ .interaction_requested_data = request },
            }) catch |err| {
                std.log.warn("rpc: cannot write interaction {d}: {t}", .{ request.interaction_id, err });
                self.fail("stdout failed while writing an interaction");
                return;
            };
        }
    }

    /// Write one JSON value as one line.
    fn writeValue(self: *Rpc, value: anytype) !void {
        std.debug.assert(!self.writing); // One line never opens inside another.
        self.writing = true;
        defer self.writing = false;
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, self.out);
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    /// Write one already-serialized result beside its request id.
    fn writeResult(self: *Rpc, id: []const u8, result_json: []const u8) !void {
        std.debug.assert(!self.writing);
        self.writing = true;
        defer self.writing = false;
        try self.out.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, self.out);
        try self.out.writeAll(",\"result\":");
        try self.out.writeAll(result_json);
        try self.out.writeAll("}\n");
        try self.out.flush();
    }

    fn writeFailure(self: *Rpc, id: []const u8, code: proto.enums.ErrorCode, message: []const u8) !void {
        return self.writeValue(proto.rpc.ResponseError{
            .id = id,
            .@"error" = .{ .code = code, .message = message },
        });
    }
};

const Request = union(enum) {
    line: []u8,
    eof,
    too_long,
    read_failed,

    fn deinit(self: *Request, gpa: std.mem.Allocator) void {
        if (self.* == .line) gpa.free(self.line);
    }
};

/// One input command, decoded so the gate can read its content.
const Input = union(enum) {
    send: proto.session.SessionSendInputParams,
    create: proto.misc.CreateSession,
};

/// One input the gate holds. The arena owns the id, the parameters, and the hook payload for the whole call.
const GatedInput = struct {
    arena: std.heap.ArenaAllocator,
    id: ?[]const u8,
    input: Input,
    call: *tools_table.Call,

    fn deinit(self: *GatedInput) void {
        self.call.finish();
        self.arena.deinit();
    }
};

/// Read requests on a task and run JavaScript only on the owner task. The caller owns `extensions`.
pub fn runIo(extensions: *extensions_mod.Extensions) !void {
    const gpa = extensions.host.gpa;
    const io = extensions.host.io;
    const application = extensions.app;
    const out_buf = try gpa.alloc(u8, out_buffer_bytes);
    defer gpa.free(out_buf);
    const in_buf = try gpa.alloc(u8, in_buffer_bytes);
    defer gpa.free(in_buf);

    // A positional write answers NXIO on a terminal, and only a pipe falls back to streaming.
    var out_file = std.Io.File.stdout().writerStreaming(io, out_buf);
    var requests_buf: [queue_slots]Request = undefined;
    var requests = zio.Channel(Request).init(&requests_buf);
    var notifications = NotificationQueue{};
    if (extensions.user_entry_fault) {
        std.log.warn("rpc: JavaScript fault in index.js: {s}", .{extensions.host.faultText()});
        extensions.host.clearFault();
    }
    var rpc: Rpc = .{
        .app = application,
        .out = &out_file.interface,
        .gpa = gpa,
        .notifications = &notifications,
        .host = extensions.host,
    };
    application.engine.sinks.add(.{ .ctx = @ptrCast(&rpc), .on_event = Rpc.onEvent });
    defer {
        application.engine.sinks.remove(@ptrCast(&rpc));
        drainNotifications(gpa, &notifications);
        rpc.deinit();
    }

    application.engine.resumeWorkspace(extensions.host.cwd) catch |err| {
        std.log.warn("cannot resume the workspace: {t}", .{err});
    };

    var readers: zio.Group = .init;
    var in_file = std.Io.File.stdin().readerStreaming(io, in_buf);
    try readers.spawn(readerTask, .{ &in_file.interface, &requests, &extensions.host.wake, gpa, extensions.host.io });
    defer {
        readers.cancel();
        drainRequests(gpa, &requests);
        requests.close(.immediate);
    }

    while (true) {
        if (rpc.fatal) return error.RpcFailed;
        var received = false;
        while (requests.tryReceive()) |request| {
            received = true;
            var item = request;
            defer item.deinit(gpa);
            switch (item) {
                .line => |line| if (trim(line).len != 0) serve(gpa, &rpc, line),
                .eof => {
                    rpc.flushNotifications();
                    return;
                },
                .too_long => {
                    rpc.flushNotifications();
                    rpc.writeFailure("", .bad_request, "the request line is too long") catch |err| rpc.failWrite(err);
                    return;
                },
                .read_failed => {
                    rpc.flushNotifications();
                    rpc.writeFailure("", .internal, "stdin read failed") catch |err| rpc.failWrite(err);
                    return;
                },
            }
            absorbOwnerPump(extensions);
            rpc.drainInputs();
            if (rpc.fatal) return error.RpcFailed;
        } else |_| {}

        absorbOwnerPump(extensions);
        rpc.drainInputs();
        rpc.flushNotifications();
        if (rpc.fatal) return error.RpcFailed;
        if (received) continue;

        extensions.host.wake.reset();
        if (requests.tryReceive()) |request| {
            requests.trySend(request) catch unreachable;
            extensions.host.wake.set(extensions.host.io);
            continue;
        } else |_| {}
        extensions.host.waitForWork(null) catch return;
    }
}

/// Copy one bounded stdin line into the owner queue. This task never enters QuickJS.
fn readerTask(reader: *std.Io.Reader, requests: *zio.Channel(Request), wake: *std.Io.Event, gpa: std.mem.Allocator, io: std.Io) !void {
    while (true) {
        const borrowed = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                requests.send(.too_long) catch return;
                wake.set(io);
                return;
            },
            error.ReadFailed => {
                requests.send(.read_failed) catch return;
                wake.set(io);
                return;
            },
        } orelse {
            requests.send(.eof) catch return;
            wake.set(io);
            return;
        };
        const line = gpa.dupe(u8, borrowed) catch {
            requests.send(.read_failed) catch return;
            wake.set(io);
            return;
        };
        requests.send(.{ .line = line }) catch {
            gpa.free(line);
            return;
        };
        wake.set(io);
    }
}

/// Free every request the owner never received. Call this before immediate channel close.
fn drainRequests(gpa: std.mem.Allocator, requests: *zio.Channel(Request)) void {
    while (requests.tryReceive()) |request| {
        var item = request;
        item.deinit(gpa);
    } else |_| {}
}

/// Free every notification the owner never wrote. Call this after removing the sink.
pub fn drainNotifications(gpa: std.mem.Allocator, notifications: *NotificationQueue) void {
    while (notifications.pop()) |owned| {
        owned.destroy(gpa);
    }
}

/// Keep the RPC stream alive after a script fault. The owner has consumed the exception.
fn absorbOwnerPump(extensions: *extensions_mod.Extensions) void {
    extensions.host.pump() catch {
        std.log.warn("rpc: JavaScript fault: {s}", .{extensions.host.faultText()});
        extensions.host.clearFault();
    };
}

/// Serve one request line and suppress the response for notifications.
pub fn serve(gpa: std.mem.Allocator, rpc: *Rpc, line: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = parse(arena, line) catch {
        rpc.writeFailure("", .bad_request, "the line is not a request object") catch |err| rpc.failWrite(err);
        return;
    };

    serveParsed(arena, rpc, request);
}

fn serveParsed(arena: std.mem.Allocator, rpc: *Rpc, request: Line) void {
    // A hooked input waits on JavaScript, so it leaves the owner and answers later.
    if (rpc.gate(request)) return;

    var body: std.Io.Writer.Allocating = .init(arena);
    const failure = call.call(rpc.app, rpc.host, arena, request.method, request.params, &body.writer) catch |err| blk: {
        std.log.err("rpc: {s} failed: {t}", .{ request.method, err });
        break :blk call.Failure{ .code = .internal, .message = "the command failed" };
    };
    rpc.respond(request.id, failure, body.written());
}

/// One decoded request line. Every field borrows the request arena.
const Line = struct {
    id: ?[]const u8,
    method: []const u8,
    /// The parameter object that `call` decodes against the method type.
    params: std.json.Value,
};

/// Decode an input method into `arena`, or return null for any other method or a bad parameter object.
fn inputOf(arena: std.mem.Allocator, request: Line) ?Input {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    if (std.mem.eql(u8, request.method, "session.send_input")) {
        return .{ .send = std.json.parseFromValueLeaky(proto.session.SessionSendInputParams, arena, request.params, options) catch return null };
    }
    if (std.mem.eql(u8, request.method, "session.create")) {
        return .{ .create = std.json.parseFromValueLeaky(proto.misc.CreateSession, arena, request.params, options) catch return null };
    }
    return null;
}

/// Read the envelope and keep the parameters as one JSON value for `call`.
fn parse(arena: std.mem.Allocator, line: []const u8) !Line {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    const obj = switch (value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const method = switch (obj.get("method") orelse return error.NoMethod) {
        .string => |s| s,
        else => return error.NoMethod,
    };
    // An absent id names a notification that receives no response.
    const id = if (obj.get("id")) |id_value| switch (id_value) {
        .string => |s| @as(?[]const u8, s),
        else => return error.BadId,
    } else null;
    // An absent params object is an empty one. `call` still decodes it against the method type.
    const params = obj.get("params") orelse std.json.Value{ .object = .{} };
    return .{ .id = id, .method = method, .params = params };
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

const testing = std.testing;
const support = @import("../js/tests/support.zig");

test "parse reads the envelope and keeps the parameters as a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try parse(arena.allocator(),
        \\{"id":"r1","method":"session.list","params":{"limit":5}}
    );
    try testing.expectEqualStrings("r1", line.id.?);
    try testing.expectEqualStrings("session.list", line.method);
    try testing.expectEqual(@as(i64, 5), line.params.object.get("limit").?.integer);
}

test "parse accepts an absent id and absent parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try parse(arena.allocator(),
        \\{"method":"initialize"}
    );
    try testing.expect(line.id == null);
    try testing.expectEqual(@as(usize, 0), line.params.object.count());
}

test "parse rejects a line that carries no request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.NotAnObject, parse(a, "[]"));
    try testing.expectError(error.NoMethod, parse(a,
        \\{"id":"r1"}
    ));
    try testing.expectError(error.BadId, parse(a,
        \\{"id":7,"method":"initialize"}
    ));
}

test "a notification does not receive a refusal response" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var notifications = NotificationQueue{};
    defer drainNotifications(testing.allocator, &notifications);
    const host = support.createHost();
    defer support.destroyHost(host);
    var rpc: Rpc = .{ .host = host, .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications };

    serve(testing.allocator, &rpc, "{\"method\":\"missing\"}");
    try testing.expectEqual(@as(usize, 0), buf.written().len);
}

test "notification queue is bounded and remains FIFO across wraparound" {
    var queue = NotificationQueue{};
    var owned: [queue_slots + 1]?*OwnedNotification = .{null} ** (queue_slots + 1);
    defer {
        for (&owned) |*item| {
            if (item.*) |value| value.destroy(testing.allocator);
        }
        drainNotifications(testing.allocator, &queue);
    }

    const note: proto.rpc.Notification = .{ .method = .notice, .params = .{ .notice = .{
        .level = .info,
        .source = "test",
        .message = "queued",
    } } };
    for (0..queue_slots) |i| {
        owned[i] = OwnedNotification.create(testing.allocator, note);
        try queue.append(owned[i].?);
    }
    const overflow = OwnedNotification.create(testing.allocator, note);
    try testing.expectError(error.Full, queue.append(overflow));
    overflow.destroy(testing.allocator);

    const first = queue.pop() orelse unreachable;
    first.destroy(testing.allocator);
    owned[0] = null;
    owned[queue_slots] = OwnedNotification.create(testing.allocator, note);
    try queue.append(owned[queue_slots].?);
    try testing.expectEqual(@as(usize, queue_slots), queue.len);
    for (1..queue_slots + 1) |i| {
        const value = queue.pop() orelse unreachable;
        try testing.expect(value == owned[i].?);
        value.destroy(testing.allocator);
        owned[i] = null;
    }
    try testing.expectEqual(@as(usize, 0), queue.len);
}

test "a blank line carries no request" {
    try testing.expectEqual(@as(usize, 0), trim("  \r").len);
    try testing.expectEqual(@as(usize, 0), trim("").len);
    try testing.expectEqualStrings("{}", trim("{}\r"));
}

test "the transport writes one line for each value" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var notifications = NotificationQueue{};
    defer drainNotifications(testing.allocator, &notifications);
    const host = support.createHost();
    defer support.destroyHost(host);
    var rpc: Rpc = .{ .host = host, .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications };

    try rpc.writeResult("r1", "{\"ok\":true}");
    try rpc.writeFailure("r2", .unknown_method, "unknown method");
    try testing.expectEqualStrings(
        \\{"id":"r1","result":{"ok":true}}
        \\{"id":"r2","error":{"code":-32601,"message":"unknown method"}}
        \\
    , buf.written());
}

test "draining queued requests releases their line payloads" {
    var requests_buf: [2]Request = undefined;
    var requests = zio.Channel(Request).init(&requests_buf);
    try requests.send(.{ .line = try testing.allocator.dupe(u8, "one") });
    try requests.send(.{ .line = try testing.allocator.dupe(u8, "two") });

    drainRequests(testing.allocator, &requests);
    try testing.expectError(error.ChannelEmpty, requests.tryReceive());
    requests.close(.immediate);
}

test "owner writes queued notifications before the response" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var notifications = NotificationQueue{};
    defer drainNotifications(testing.allocator, &notifications);
    const host = support.createHost();
    defer support.destroyHost(host);
    var rpc: Rpc = .{ .host = host, .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications };
    const note: proto.rpc.Notification = .{ .method = .notice, .params = .{ .notice = .{
        .level = .info,
        .source = "test",
        .message = "queued",
    } } };
    try notifications.append(OwnedNotification.create(testing.allocator, note));

    rpc.flushNotifications();
    try rpc.writeResult("r1", "{\"ok\":true}");
    try testing.expectEqualStrings(
        "{\"method\":\"notice\",\"params\":{\"level\":\"info\",\"source\":\"test\",\"message\":\"queued\"}}\n" ++
            "{\"id\":\"r1\",\"result\":{\"ok\":true}}\n",
        buf.written(),
    );
}

test "the sink callback queues an owned notification without writing" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var notifications = NotificationQueue{};
    defer drainNotifications(testing.allocator, &notifications);
    const host = support.createHost();
    defer support.destroyHost(host);
    var rpc: Rpc = .{ .host = host, .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications };
    var message = [_]u8{ 'q', 'u', 'e', 'u', 'e', 'd' };
    const note: proto.rpc.Notification = .{ .method = .notice, .params = .{ .notice = .{
        .level = .info,
        .source = "test",
        .message = &message,
    } } };

    Rpc.onEvent(@ptrCast(&rpc), note);
    message[0] = 'x';
    try testing.expectEqual(@as(usize, 0), buf.written().len);
    try testing.expectEqual(@as(usize, 1), notifications.len);
    const queued = notifications.pop() orelse unreachable;
    defer queued.destroy(testing.allocator);
    try testing.expectEqualStrings("queued", queued.value.params.notice.message);
}
