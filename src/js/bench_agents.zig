//! Stored trees exercise the real engine reads from the agent picker.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const fixture = @import("../app/fixture.zig");
const App = @import("../app/app.zig").App;
const Host = @import("host.zig").Host;
const store = @import("../store/store.zig");
const Tree = @This();

pub const Shape = enum { wide, balanced };
gpa: std.mem.Allocator,
app: App,
transport: ai.transport.CannedTransport,

fn id(n: u64) proto.ids.SessionId {
    return .bytes(std.mem.toBytes(@as(u128, n + 1)));
}

pub fn create(host: *Host, count: u32, shape: Shape) !*Tree {
    std.debug.assert(count > 0);
    const self = try host.gpa.create(Tree);
    errdefer host.gpa.destroy(self);
    self.* = .{ .gpa = host.gpa, .app = undefined, .transport = .{ .bytes = "" } };
    try fixture.init(&self.app, host.gpa, host.io, host.cwd, host.execution, self.transport.transport());
    errdefer self.app.deinit();
    var tx = try self.app.db.begin();
    defer tx.deinit();
    for (0..@as(usize, count) + 1) |n| {
        const parent = if (shape == .wide) 0 else (n -| 1) / 4;
        var name: [32]u8 = undefined;
        try store.session.create(&self.app.db, .{
            .id = id(n).raw,
            .root = "/bench",
            .origin = if (n == 0) "root" else "child",
            .parent_id = if (n == 0) null else id(parent).raw,
            .parent_message_id = if (n == 0) null else 1,
            .parent_part_id = if (n == 0) null else 0,
            .profile = "default",
            .model = "bench/model",
            .reasoning = "high",
            .config_rev = 0,
            .title = "bench",
            .name = if (n == 0) null else try std.fmt.bufPrint(&name, "agent-{d}", .{n}),
            .created_at_ms = 1,
            .updated_at_ms = n + 1,
        });
        if (n % 2 == 0) _ = try self.app.engine.sessions.getOrCreate(id(n));
    }
    try tx.commit();
    const global = host.ctx.getGlobalObject();
    defer host.ctx.freeValue(global);
    try host.ctx.setPropertyStr(global, "AGENTS_ROOT", host.ctx.newString(&std.fmt.bytesToHex(id(0).raw, .lower)));
    try host.ctx.setPropertyStr(global, "AGENTS_TARGET", host.ctx.newString(&std.fmt.bytesToHex(id(count).raw, .lower)));
    host.engine.attach(&self.app);
    return self;
}

pub fn destroy(self: *Tree) void {
    const gpa = self.gpa;
    self.app.deinit();
    gpa.destroy(self);
}
