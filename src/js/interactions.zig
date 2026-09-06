//! Pending frontend questions owned by one QuickJS host.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const pending = @import("pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The admission cap on the questions that wait for an answer.
pub const max_pending: usize = 32;
pub const max_options: usize = 64;
pub const max_text_bytes: usize = 64 * 1024;
pub const max_safe_id: u64 = (1 << 53) - 1;

pub const Error = error{
    Unavailable,
    Duplicate,
    Full,
    InvalidRequest,
    Unknown,
    ResponseMismatch,
    InvalidSelection,
    /// The QuickJS heap is full. The exception stays pending, so the caller throws it.
    Exception,
};

/// One question. The arena owns every slice `value` holds.
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    id: proto.ids.InteractionId,
    value: proto.interaction.InteractionRequest,
    op: *pending.Op,
    sent: bool = false,
    /// A cancellation watch: never shown, never answered by a peer.
    hidden: bool = false,
    session_id: ?proto.ids.SessionId = null,
};

/// The questions this host waits on, oldest first.
pub const Table = struct {
    gpa: std.mem.Allocator,
    live: std.ArrayList(*Request) = .empty,
    accepting: bool = true,

    pub fn deinit(self: *Table) void {
        for (self.live.items) |request| self.destroy(request);
        self.live.deinit(self.gpa);
        self.* = undefined;
    }

    /// Stop new work and cancel every question before the JavaScript context closes.
    pub fn close(self: *Table) void {
        std.debug.assert(self.accepting);
        self.accepting = false;
        // A shutdown answers like a cancel, so a gate that waits denies instead of throwing.
        for (self.live.items) |request| {
            request.op.finish(if (request.hidden) .{ .failed = .{ .message = "the host closed" } } else .undefined);
            self.destroy(request);
        }
        self.live.clearRetainingCapacity();
    }

    /// Queue one question and return the Promise that its correlated answer settles.
    pub fn start(
        self: *Table,
        ops: *pending.Ops,
        ctx: Context,
        id: proto.ids.InteractionId,
        json: []const u8,
    ) Error!Value {
        if (!self.accepting) return error.Unavailable;
        if (id == 0 or id > max_safe_id) return error.InvalidRequest;
        if (self.indexOf(id) != null) return error.Duplicate;
        if (self.live.items.len == max_pending) return error.Full;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const value = std.json.parseFromSliceLeaky(
            proto.interaction.InteractionRequest,
            arena.allocator(),
            json,
            .{},
        ) catch return error.InvalidRequest;
        try validate(value);

        const started = ops.start(ctx) orelse return error.Exception;
        const request = self.gpa.create(Request) catch unreachable;
        request.* = .{ .arena = arena, .id = id, .value = value, .op = started.op };
        self.live.append(self.gpa, request) catch unreachable;
        return started.promise;
    }

    /// A hidden request observes the exact tool signal through the same cancellation table.
    pub fn watchCancellation(self: *Table, ops: *pending.Ops, ctx: Context, id: proto.ids.InteractionId, signal: Value) Error!Value {
        const promise = try self.start(ops, ctx, id, "{\"type\":\"confirm\",\"title\":\"cancel\",\"message\":\"\"}");
        const request = self.live.items[self.indexOf(id).?];
        request.sent = true;
        request.hidden = true;
        self.attribute(ctx, id, null, signal);
        return promise;
    }

    /// Answer the oldest question the frontend has not seen and mark it sent.
    pub fn takeNext(self: *Table) ?proto.interaction.InteractionRequestedData {
        for (self.live.items) |request| {
            if (request.sent) continue;
            request.sent = true;
            return .{ .interaction_id = request.id, .request = request.value, .session_id = request.session_id };
        }
        return null;
    }

    pub fn attribute(self: *Table, ctx: Context, id: proto.ids.InteractionId, session_id: ?proto.ids.SessionId, signal: Value) void {
        const request = self.live.items[self.indexOf(id).?];
        std.debug.assert(request.session_id == null);
        request.session_id = session_id;
        request.op.signal = ctx.dupValue(signal);
    }

    pub fn cancelSignal(self: *Table, ctx: Context, signal: Value) void {
        var i: usize = 0;
        while (i < self.live.items.len) {
            const request = self.live.items[i];
            if (!ctx.isStrictEqual(request.op.signal, signal)) {
                i += 1;
                continue;
            }
            std.debug.assert(self.cancel(request.id));
        }
    }

    /// Settle one question. Bad peer input leaves the original question pending.
    pub fn respond(self: *Table, params: proto.interaction.InteractionRespondParams) Error!void {
        const index = self.indexOf(params.interaction_id) orelse return error.Unknown;
        const request = self.live.items[index];
        if (!request.sent or request.hidden) return error.Unknown;
        const result = try self.resultFor(request, params.response);
        _ = self.live.orderedRemove(index);
        request.op.finish(result);
        self.destroy(request);
    }

    /// Cancel one consumer-owned question. A late frontend answer becomes unknown.
    pub fn cancel(self: *Table, id: proto.ids.InteractionId) bool {
        const index = self.indexOf(id) orelse return false;
        const request = self.live.orderedRemove(index);
        request.op.finish(.undefined);
        self.destroy(request);
        return true;
    }

    fn resultFor(self: *Table, request: *const Request, response: proto.interaction.InteractionResponse) Error!pending.Result {
        if (!matches(request.value, response)) return error.ResponseMismatch;
        return switch (response) {
            .canceled => .undefined,
            .confirm => |answer| .{ .boolean = answer.value },
            .select => |answer| blk: {
                for (request.value.select.options) |option| {
                    if (std.mem.eql(u8, option, answer.value)) break :blk .{ .text = self.gpa.dupe(u8, answer.value) catch unreachable };
                } else return error.InvalidSelection;
            },
            .input => |answer| blk: {
                try validateText(answer.value, .optional);
                break :blk .{ .text = self.gpa.dupe(u8, answer.value) catch unreachable };
            },
        };
    }

    fn destroy(self: *Table, request: *Request) void {
        request.arena.deinit();
        self.gpa.destroy(request);
    }

    fn indexOf(self: *const Table, id: proto.ids.InteractionId) ?usize {
        for (self.live.items, 0..) |request, i| if (request.id == id) return i;
        return null;
    }
};

/// Report whether the answer arm pairs with the question arm.
fn matches(request: proto.interaction.InteractionRequest, response: proto.interaction.InteractionResponse) bool {
    return switch (response) {
        .canceled => true,
        .confirm => request == .confirm,
        .select => request == .select,
        .input => request == .input,
    };
}

fn validate(request: proto.interaction.InteractionRequest) Error!void {
    switch (request) {
        .confirm => |value| {
            try validateText(value.title, .required);
            try validateText(value.message, .optional);
        },
        .select => |value| {
            try validateText(value.title, .required);
            if (value.options.len == 0 or value.options.len > max_options) return error.InvalidRequest;
            for (value.options, 0..) |option, i| {
                try validateText(option, .required);
                for (value.options[0..i]) |previous| {
                    if (std.mem.eql(u8, option, previous)) return error.InvalidRequest;
                }
            }
        },
        .input => |value| {
            try validateText(value.title, .required);
            if (value.placeholder) |placeholder| try validateText(placeholder, .optional);
        },
    }
}

fn validateText(text: []const u8, presence: enum { required, optional }) Error!void {
    if ((presence == .required and text.len == 0) or text.len > max_text_bytes or !std.unicode.utf8ValidateSlice(text))
        return error.InvalidRequest;
}
