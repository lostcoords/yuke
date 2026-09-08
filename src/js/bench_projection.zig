//! A resident session exercises the real native projection and client page reads.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const App = @import("../app/app.zig").App;
const Database = @import("../store/store.zig").Database;
const Host = @import("host.zig").Host;
const paging = @import("native/engine/paging.zig");
const Session = @import("../session/session.zig").Session;
const Projection = @This();

gpa: std.mem.Allocator,
app: App,
transport: ai.transport.CannedTransport,
session: *Session,
session_id: proto.ids.SessionId,
stream_offset: usize = 0,
source_bytes: usize = 0,

pub fn create(host: *Host, io: std.Io, env: *const std.process.Environ.Map, scale: u32, native_stream: bool) !*Projection {
    std.debug.assert(scale > 0);
    const gpa = host.gpa;
    const self = try gpa.create(Projection);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .app = undefined, .transport = .{ .bytes = "" }, .session = undefined, .session_id = undefined };
    var db = try Database.openTest();
    errdefer db.deinit();
    try self.app.initTest(gpa, io, db, env, self.transport.transport());
    errdefer self.app.logins.deinit();
    errdefer self.app.store.deinit();
    errdefer self.app.engine.close();
    const sid = proto.ids.SessionId.bytes([_]u8{7} ** 16);
    const session = try self.app.engine.sessions.getOrCreate(sid);
    self.session = session;
    self.session_id = sid;
    const unit = "A paragraph 世界 é 👩‍💻.\n\n";
    const body = try gpa.alloc(u8, unit.len * 2048 * scale);
    defer gpa.free(body);
    var at: usize = 0;
    while (at < body.len) : (at += unit.len) @memcpy(body[at..][0..unit.len], unit);
    const parts = [_]proto.message.AssistantPart{.{ .text = .{ .id = 0, .text = body } }};
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "bench",
        .content = &parts,
        .time = .{ .created_at_ms = 1 },
    } }};
    try paging.seedHistory(session, &messages);
    if (native_stream) {
        try session.apply(.{ .message_started_data = .{
            .session_id = sid,
            .message_id = 2,
            .run_id = 2,
            .config_rev = 0,
            .agent = "bench",
            .created_at_ms = 2,
        } });
        try session.apply(.{ .message_part_added_data = .{
            .session_id = sid,
            .message_id = 2,
            .part = .{ .text = .{ .id = 0, .text = body } },
        } });
        self.stream_offset = body.len;
    }
    self.source_bytes = body.len;
    const ctx = host.ctx;
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    try ctx.setPropertyStr(global, "PROJECTION_TEXT", ctx.newString(body));
    try ctx.setPropertyStr(global, "PROJECTION_SESSION", ctx.newString(&std.fmt.bytesToHex(sid.raw, .lower)));
    try ctx.setPropertyStr(global, "STREAM_NATIVE_INITIAL_BYTES", ctx.newUint32(@intCast(body.len)));
    host.engine.attach(&self.app);
    return self;
}

pub fn sourceBytes(self: *const Projection) u64 {
    return @intCast(self.source_bytes);
}

pub fn appendNative(self: *Projection, step: usize) !void {
    const deltas = [_][]const u8{ " word", " 世界", " e\u{301}", " 👩‍💻", "\n\n" };
    const delta = deltas[step % deltas.len];
    try self.session.apply(.{ .message_part_delta_data = .{
        .session_id = self.session_id,
        .message_id = 2,
        .part_id = 0,
        .delta = delta,
        .offset = self.stream_offset,
    } });
    self.stream_offset += delta.len;
}

pub fn destroy(self: *Projection) void {
    const gpa = self.gpa;
    self.app.engine.close();
    self.app.db.deinit();
    self.app.store.deinit();
    self.app.logins.deinit();
    gpa.destroy(self);
}
