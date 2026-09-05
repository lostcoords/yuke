//! The JSONL stdio transport queues input and events so only the QuickJS owner writes output.

const std = @import("std");
const proto = @import("proto");
const app = @import("app.zig");
const call = @import("call.zig");
const extensions_mod = @import("../js/extensions.zig");
const interactions_mod = @import("../js/interactions.zig");
const tools_table = @import("../js/tools.zig");
const Host = extensions_mod.Host;
const zio = @import("zio");

const App = app.App;

const InteractionFailure = error{ Unknown, ResponseMismatch, InvalidSelection, Internal };

/// The interaction table, type-erased. A direct call would pull the JavaScript host into this module.
const InteractionPort = struct {
    ctx: *anyopaque,
    take_next: *const fn (*anyopaque) ?proto.interaction.InteractionRequestedData,
    respond: *const fn (*anyopaque, proto.interaction.InteractionRespondParams) InteractionFailure!void,
};

/// Answer the port for one live table. Only a module that owns the host calls this.
pub fn interactionPort(table: *interactions_mod.Table) InteractionPort {
    const adapter = struct {
        fn takeNext(ctx: *anyopaque) ?proto.interaction.InteractionRequestedData {
            const held: *interactions_mod.Table = @ptrCast(@alignCast(ctx));
            return held.takeNext();
        }

        fn respond(ctx: *anyopaque, params: proto.interaction.InteractionRespondParams) InteractionFailure!void {
            const held: *interactions_mod.Table = @ptrCast(@alignCast(ctx));
            held.respond(params) catch |err| return switch (err) {
                error.Unknown => error.Unknown,
                error.ResponseMismatch => error.ResponseMismatch,
                error.InvalidSelection => error.InvalidSelection,
                else => error.Internal,
            };
        }
    };
    return .{ .ctx = @ptrCast(table), .take_next = adapter.takeNext, .respond = adapter.respond };
}

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

    fn create(gpa: std.mem.Allocator, value: proto.rpc.Notification) ?*OwnedNotification {
        const owned = gpa.create(OwnedNotification) catch return null;
        owned.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .value = undefined };
        owned.value = proto.clone.dupe(owned.arena.allocator(), value) catch {
            owned.arena.deinit();
            gpa.destroy(owned);
            return null;
        };
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
    wake: *zio.ResetEvent,
    interactions: ?InteractionPort = null,
    /// The host whose gate reads a hooked input. A test stream without a host serves every line inline.
    host: ?*Host = null,
    /// The inputs the gate holds. Each one writes its answer after the owner settles its call.
    inputs: std.ArrayList(GatedInput) = .empty,
    fatal: bool = false,
    /// Set while a line goes out. Two writers would interleave one line inside another.
    writing: bool = false,

    /// Leave every held input and free the list. The owner sweeps the call records on its next pump.
    pub fn deinit(self: *Rpc) void {
        for (self.inputs.items) |input| input.drop(self.gpa);
        self.inputs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Hand one input to the gate. The answer goes out from `drainInputs` once the owner settles the call.
    fn gateInput(self: *Rpc, host: *Host, request: Line) void {
        if (self.inputs.items.len == queue_slots) {
            self.flushNotifications();
            if (request.id) |id| self.writeFailure(id, .queue_full, "too many requests are pending") catch |err| self.failWrite(err);
            return;
        }
        const params = self.gpa.dupe(u8, request.params) catch unreachable;
        const id = if (request.id) |value| self.gpa.dupe(u8, value) catch unreachable else null;
        self.inputs.append(self.gpa, .{ .id = id, .params = params, .call = host.calls.submitInput(params) }) catch unreachable;
    }

    /// Write every gated input the owner settled. The owner is the only writer.
    pub fn drainInputs(self: *Rpc) void {
        var i: usize = 0;
        while (i < self.inputs.items.len) {
            const input = self.inputs.items[i];
            if (input.call.state != .settled) {
                i += 1;
                continue;
            }
            _ = self.inputs.orderedRemove(i);
            defer input.drop(self.gpa);
            self.flushNotifications();
            if (self.fatal) return;
            if (input.id) |id| self.writeGated(id, input.call);
        }
    }

    /// Decode the gate's `{result}` or `{failure}` object and write it under `id`.
    fn writeGated(self: *Rpc, id: []const u8, call_record: *const tools_table.Call) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const text = call_record.text orelse "";
        const answer = if (call_record.is_error) null else std.json.parseFromSliceLeaky(GateAnswer, arena, text, .{ .ignore_unknown_fields = true }) catch null;
        const decoded = answer orelse {
            std.log.err("rpc: the input gate answered: {s}", .{text});
            self.writeFailure(id, .internal, "the input gate failed") catch |err| self.failWrite(err);
            return;
        };
        if (decoded.failure) |failure| {
            const code = std.meta.stringToEnum(proto.enums.ErrorCode, failure.code) orelse .internal;
            self.writeFailure(id, code, failure.message) catch |err| self.failWrite(err);
            return;
        }
        var body: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(decoded.result, .{}, &body.writer) catch unreachable;
        self.writeResult(id, body.written()) catch |err| self.failWrite(err);
    }

    /// Queue one engine event without entering the owner or waiting on stdout.
    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *Rpc = @ptrCast(@alignCast(ctx));
        const owned = OwnedNotification.create(self.gpa, note) orelse {
            self.fail("out of memory while queueing a notification");
            return;
        };
        self.notifications.append(owned) catch {
            owned.destroy(self.gpa);
            self.fail("notification queue is full");
        };
    }

    /// Mark the stream fatal and wake the owner to stop with no silent event loss.
    fn fail(self: *Rpc, message: []const u8) void {
        if (!self.fatal) std.log.err("rpc: {s}", .{message});
        self.fatal = true;
        self.wake.set();
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
        const port = self.interactions orelse return;
        // `take_next` marks the question sent before the write. A failed write is fatal, so no answer is lost.
        while (port.take_next(port.ctx)) |request| {
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
        std.debug.assert(!self.writing); // one line never opens inside another
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

/// One `session.send_input` the gate holds. The record owns the parameter bytes for the whole call.
const GatedInput = struct {
    id: ?[]u8,
    params: []u8,
    call: *tools_table.Call,

    fn drop(self: GatedInput, gpa: std.mem.Allocator) void {
        self.call.finish();
        if (self.id) |id| gpa.free(id);
        gpa.free(self.params);
    }
};

/// What the gate answers: the command result, or the refusal with its wire code.
const GateAnswer = struct {
    result: std.json.Value = .null,
    failure: ?struct { code: []const u8, message: []const u8 } = null,
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

    var out_file = std.Io.File.stdout().writer(io, out_buf);
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
        .wake = &extensions.host.wake,
        .interactions = interactionPort(&extensions.host.interactions),
        .host = extensions.host,
    };
    application.engine.sinks.add(.{ .ctx = @ptrCast(&rpc), .on_event = Rpc.onEvent });
    defer {
        application.engine.sinks.remove(@ptrCast(&rpc));
        drainNotifications(gpa, &notifications);
        rpc.deinit();
    }

    var readers: zio.Group = .init;
    var in_file = std.Io.File.stdin().reader(io, in_buf);
    try readers.spawn(readerTask, .{ &in_file.interface, &requests, &extensions.host.wake, gpa });
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
            extensions.host.wake.set();
            continue;
        } else |_| {}
        if (extensions.host.hasPending()) continue;
        extensions.host.wake.wait() catch return;
    }
}

/// Copy one bounded stdin line into the owner queue. This task never enters QuickJS.
fn readerTask(reader: *std.Io.Reader, requests: *zio.Channel(Request), wake: *zio.ResetEvent, gpa: std.mem.Allocator) !void {
    while (true) {
        const borrowed = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                requests.send(.too_long) catch return;
                wake.set();
                return;
            },
            error.ReadFailed => {
                requests.send(.read_failed) catch return;
                wake.set();
                return;
            },
        } orelse {
            requests.send(.eof) catch return;
            wake.set();
            return;
        };
        const line = gpa.dupe(u8, borrowed) catch {
            requests.send(.read_failed) catch return;
            wake.set();
            return;
        };
        requests.send(.{ .line = line }) catch {
            gpa.free(line);
            return;
        };
        wake.set();
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
    if (std.mem.eql(u8, request.method, "interaction.respond")) {
        serveInteraction(arena, rpc, request);
        return;
    }
    // A hooked input waits on JavaScript, so it leaves the owner and answers later.
    if (rpc.host) |host| if (std.mem.eql(u8, request.method, "session.send_input") and host.hooks.holds(.@"input.before")) {
        return rpc.gateInput(host, request);
    };

    var body: std.Io.Writer.Allocating = .init(arena);
    const failure = call.call(rpc.app, arena, request.method, request.params, &body.writer) catch |err| {
        std.log.err("rpc: {s} failed: {t}", .{ request.method, err });
        rpc.flushNotifications();
        if (request.id) |id| {
            rpc.writeFailure(id, .internal, "the command failed") catch |write_err| rpc.failWrite(write_err);
        }
        return;
    };
    rpc.flushNotifications();
    if (failure) |f| {
        if (request.id) |id| {
            rpc.writeFailure(id, f.code, f.message) catch |err| rpc.failWrite(err);
        }
        return;
    }
    if (request.id) |id| {
        rpc.writeResult(id, body.written()) catch |err| rpc.failWrite(err);
    }
}

fn serveInteraction(arena: std.mem.Allocator, rpc: *Rpc, request: Line) void {
    const port = rpc.interactions orelse {
        if (request.id) |id| rpc.writeFailure(id, .internal, "interaction is unavailable") catch |err| rpc.failWrite(err);
        return;
    };
    const params = std.json.parseFromSliceLeaky(
        proto.interaction.InteractionRespondParams,
        arena,
        request.params,
        .{ .ignore_unknown_fields = true },
    ) catch {
        rpc.flushNotifications();
        if (request.id) |id| rpc.writeFailure(id, .bad_request, "bad interaction response") catch |err| rpc.failWrite(err);
        return;
    };
    port.respond(port.ctx, params) catch |err| {
        const failure: struct { code: proto.enums.ErrorCode, message: []const u8 } = switch (err) {
            error.Unknown => .{ .code = .unknown_interaction, .message = "unknown interaction" },
            error.ResponseMismatch => .{ .code = .bad_request, .message = "the interaction response has the wrong type" },
            error.InvalidSelection => .{ .code = .bad_request, .message = "the interaction selected an unknown option" },
            error.Internal => .{ .code = .internal, .message = "the interaction response failed" },
        };
        rpc.flushNotifications();
        if (request.id) |id| rpc.writeFailure(id, failure.code, failure.message) catch |write_err| rpc.failWrite(write_err);
        return;
    };
    rpc.flushNotifications();
    if (request.id) |id| rpc.writeResult(id, "{}") catch |err| rpc.failWrite(err);
}

/// One decoded request line. Every field borrows the request arena.
const Line = struct {
    id: ?[]const u8,
    method: []const u8,
    /// The raw parameter object. `call` decodes it against the method's own type.
    params: []const u8,
};

/// Read the envelope and keep the parameters as text. The transport never decodes a payload itself.
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
    const params = if (obj.get("params")) |value_params| blk: {
        var text: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(value_params, .{ .emit_null_optional_fields = false }, &text.writer);
        break :blk text.written();
    } else "{}";
    return .{ .id = id, .method = method, .params = params };
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

const testing = std.testing;

test "parse reads the envelope and keeps the parameters as text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try parse(arena.allocator(),
        \\{"id":"r1","method":"session.list","params":{"limit":5}}
    );
    try testing.expectEqualStrings("r1", line.id.?);
    try testing.expectEqualStrings("session.list", line.method);
    try testing.expectEqualStrings("{\"limit\":5}", line.params);
}

test "parse accepts an absent id and absent parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try parse(arena.allocator(),
        \\{"method":"initialize"}
    );
    try testing.expect(line.id == null);
    try testing.expectEqualStrings("{}", line.params);
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
    var wake = zio.ResetEvent.init;
    var rpc: Rpc = .{ .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications, .wake = &wake };

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
        owned[i] = OwnedNotification.create(testing.allocator, note) orelse return error.OutOfMemory;
        try queue.append(owned[i].?);
    }
    const overflow = OwnedNotification.create(testing.allocator, note) orelse return error.OutOfMemory;
    try testing.expectError(error.Full, queue.append(overflow));
    overflow.destroy(testing.allocator);

    const first = queue.pop() orelse unreachable;
    first.destroy(testing.allocator);
    owned[0] = null;
    owned[queue_slots] = OwnedNotification.create(testing.allocator, note) orelse return error.OutOfMemory;
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
    var wake = zio.ResetEvent.init;
    var rpc: Rpc = .{ .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications, .wake = &wake };

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
    var wake = zio.ResetEvent.init;
    var rpc: Rpc = .{ .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications, .wake = &wake };
    const note: proto.rpc.Notification = .{ .method = .notice, .params = .{ .notice = .{
        .level = .info,
        .source = "test",
        .message = "queued",
    } } };
    try notifications.append(OwnedNotification.create(testing.allocator, note) orelse return error.OutOfMemory);

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
    var wake = zio.ResetEvent.init;
    var rpc: Rpc = .{ .app = undefined, .out = &buf.writer, .gpa = testing.allocator, .notifications = &notifications, .wake = &wake };
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
