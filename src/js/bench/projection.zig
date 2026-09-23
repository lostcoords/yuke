//! A resident session exercises the real native projection and client page reads.

const std = @import("std");
const app_fixture = @import("../../app/fixture.zig");
const proto = @import("proto");
const ai = @import("ai");
const App = @import("../../app/app.zig").App;
const Database = @import("../../store/store.zig").Database;
const Host = @import("../host.zig").Host;
const paging = @import("../native/engine/paging.zig");
const Session = @import("../../session/session.zig").Session;
const Projection = @This();

gpa: std.mem.Allocator,
app: App,
transport: ai.testing.CannedTransport,
session: *Session,
session_id: proto.ids.SessionId,
stream_offset: usize = 0,
source_bytes: usize = 0,

/// The stream phase grows no live part, the text part of message 2, or the tool output part of message 2.
pub const Stream = enum { none, text, tool };

/// The part id of the running tool in message 2.
pub const tool_part_id: proto.ids.PartId = 1;
/// One step of tool output: build-log lines about the size of one pipe read in a busy build.
const tool_chunk = "[ 42%] Building CXX object src/engine/CMakeFiles/engine.dir/turn.cpp.o\n" ** 14;
/// The output a tool held before the first step, so each read already passes one page.
const tool_seed_bytes = 64 * 1024;

pub fn create(host: *Host, io: std.Io, scale: u32, stream: Stream) !*Projection {
    std.debug.assert(scale > 0);
    const gpa = host.gpa;
    const self = try gpa.create(Projection);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .app = undefined, .transport = .{ .bytes = "" }, .session = undefined, .session_id = undefined };
    // The bench never puts a blob, so the host working directory stands in for the store.
    try app_fixture.init(&self.app, gpa, io, host.cwd, self.transport.transport(), host.execution);
    errdefer self.app.deinit();
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
        .content = &parts,
        .time = .{ .created_at_ms = 1 },
    } }};
    try paging.seedHistory(session, &messages);
    if (stream != .none) {
        try session.apply(.{ .message_started_data = .{
            .session_id = sid,
            .message_id = 2,
            .run_id = 2,
            .config_rev = 0,
            .created_at_ms = 2,
        } });
        try session.apply(.{ .message_part_added_data = .{
            .session_id = sid,
            .message_id = 2,
            .part = .{ .text = .{ .id = 0, .text = body } },
        } });
        self.stream_offset = body.len;
    }
    if (stream == .tool) {
        try session.apply(.{ .message_part_added_data = .{
            .session_id = sid,
            .message_id = 2,
            .part = .{ .tool = .{ .id = tool_part_id, .name = "exec", .arguments = "{\"command\":\"make\"}", .state = .pending } },
        } });
        try session.apply(.{ .tool_state_changed_data = .{
            .session_id = sid,
            .message_id = 2,
            .part_id = tool_part_id,
            .state = .{ .running = .{ .started_at_ms = 3 } },
        } });
        self.stream_offset = 0;
        while (self.stream_offset < tool_seed_bytes) try self.appendTool();
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

/// Append one chunk of output to the running tool, as the engine does for a `tool.output_delta`.
pub fn appendTool(self: *Projection) !void {
    if (self.stream_offset + tool_chunk.len > proto.meta.limits.max_tool_output_stream_bytes) return error.ToolStreamFull;
    try self.session.apply(.{ .tool_output_delta_data = .{
        .session_id = self.session_id,
        .message_id = 2,
        .part_id = tool_part_id,
        .delta = tool_chunk,
        .offset = self.stream_offset,
    } });
    self.stream_offset += tool_chunk.len;
}

pub fn destroy(self: *Projection) void {
    const gpa = self.gpa;
    self.app.deinit();
    gpa.destroy(self);
}
