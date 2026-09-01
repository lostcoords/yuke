//! One device login the daemon owns. It outlives the connection that asked for it.

const std = @import("std");
const wire = @import("wire");
const provider = @import("../provider/provider.zig");

const oauth = provider.oauth;

/// The flows this daemon can drive. The catalog row names one; an unknown name is not a login.
pub const Flow = enum {
    xai,
    codex,

    pub fn parse(name: []const u8) ?Flow {
        return std.meta.stringToEnum(Flow, name);
    }
};

/// One live login. The RPC task sets the flag and the event; the login task reads both.
pub const LoginSlot = struct {
    arena: std.heap.ArenaAllocator,
    id: wire.ids.LoginId,
    /// The arena owns this copy, so it outlives the request that named the provider.
    provider_id: []const u8,
    flow: Flow,
    /// The reservation holds no code until `start` answers, so a second attempt still sees it.
    start: oauth.Start = .{ .user_code = "", .device_auth_id = "", .verification_url = "" },
    /// A cancel sets this before it wakes the task, so the task reports `canceled`.
    cancel_requested: bool = false,
    /// The RPC task sets this event so a waiting login stops before its next poll.
    wake_event: std.Io.Event = .unset,

    pub fn destroy(self: *LoginSlot, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Every live login, keyed by id. One provider holds at most one login at a time.
pub const Logins = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(wire.ids.LoginId, *LoginSlot) = .empty,

    pub fn init(gpa: std.mem.Allocator) Logins {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Logins) void {
        var it = self.map.valueIterator();
        while (it.next()) |slot| slot.*.destroy(self.gpa);
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *Logins, id: wire.ids.LoginId) ?*LoginSlot {
        return self.map.get(id);
    }

    /// Report the live login of one provider, so a second attempt joins it instead of racing.
    pub fn byProvider(self: *Logins, provider_id: []const u8) ?*LoginSlot {
        var it = self.map.valueIterator();
        while (it.next()) |slot| {
            if (std.mem.eql(u8, slot.*.provider_id, provider_id)) return slot.*;
        }
        return null;
    }

    /// Reserve the provider and take its arena, before any call that can yield.
    /// The registry owns the arena from here, so the caller frees the slot only through `remove`.
    pub fn reserve(self: *Logins, id: wire.ids.LoginId, arena: std.heap.ArenaAllocator, provider_id: []const u8, flow: Flow) !*LoginSlot {
        const slot = try self.gpa.create(LoginSlot);
        errdefer self.gpa.destroy(slot);
        slot.* = .{ .arena = arena, .id = id, .provider_id = provider_id, .flow = flow };
        try self.map.put(self.gpa, id, slot);
        return slot;
    }

    /// Drop one finished login. The slot and its arena go with it.
    pub fn remove(self: *Logins, id: wire.ids.LoginId) void {
        const entry = self.map.fetchRemove(id) orelse return;
        entry.value.destroy(self.gpa);
    }
};

const testing = std.testing;

test "one provider holds one login, and a removal frees it" {
    var logins: Logins = .init(testing.allocator);
    defer logins.deinit();

    const id: wire.ids.LoginId = .bytes(@splat(1));
    const arena: std.heap.ArenaAllocator = .init(testing.allocator);
    const slot = try logins.reserve(id, arena, "codex", .codex);

    try testing.expect(logins.get(id) == slot);
    try testing.expect(logins.byProvider("codex") == slot);
    try testing.expect(logins.byProvider("other") == null);

    logins.remove(id);
    try testing.expect(logins.get(id) == null);
    try testing.expect(logins.byProvider("codex") == null);
}
