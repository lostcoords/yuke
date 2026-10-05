//! Long agent runs drive the production engine, store, and request path with no network. Several sessions can run at the same time.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");
const zqlite = @import("zqlite");
const fixture = @import("../../app/fixture.zig");
const App = @import("../../app/app.zig").App;
const Host = @import("../host.zig").Host;
const commands = @import("../../engine/commands.zig");
const toolset = @import("../../engine/toolset.zig");
const provider = @import("../../provider/provider.zig");
const store = @import("../../store/store.zig");
const Run = @This();

/// The tool output of one round, near the size of one `read` of a source file.
const output_bytes = 38 * 1024;
/// The reasoning signature of one round. A real provider replays it in every later request.
const signature_bytes = 2000;
const frame = ai.testing.sseFrame;
const png_signature = "\x89PNG\r\n\x1a\n";
/// The text that names a session in its first prompt. No other part of a body holds it.
const session_tag = "bench-session-";
const read_decl = [_]toolset.Served{.{ .decl = .{ .name = "read", .description = "Read a part of the corpus.", .input_schema = "{\"type\":\"object\",\"properties\":{\"part\":{\"type\":\"integer\"}},\"required\":[\"part\"]}" }, .id = 0 }};

gpa: std.mem.Allocator,
app: App,
rounds: u32,
/// The sessions that one step runs at the same time.
sessions: u32,
/// The wait before each answer, as a provider takes before its first byte. Sessions overlap during it.
latency_ms: u32,
/// The tool rounds of one run. The final text answer is `ai.testing.canned_reply`.
replies: []const []const u8,
/// The text that the tool answers. Each round reads another window of it.
corpus: []const u8,
/// The size of the image beside each tool output. Zero answers text alone.
image_bytes: u32,
/// The requests of one step, over all sessions.
served: u32 = 0,
/// The requests of each session in one step. The prompt of session `i` names `i`.
progress: []u32,
/// The tool calls of one step. Each call reads another window of the corpus.
reads: u32 = 0,
/// The largest body of one step, so a report can relate memory to the history size.
last_body_bytes: usize = 0,

/// The work of one run beside its rounds. The defaults run one session with no answer delay and no image.
pub const Load = struct {
    sessions: u32 = 1,
    latency_ms: u32 = 0,
    image_bytes: u32 = 0,
};

/// Own one App on an in-memory database, the canned replies, and the corpus. It fails on OOM or a store error.
pub fn create(host: *Host, rounds: u32, load: Load) !*Run {
    std.debug.assert(rounds > 0 and load.sessions > 0);
    std.debug.assert(load.image_bytes == 0 or load.image_bytes > png_signature.len + 4);
    const gpa = host.gpa;
    const self = try gpa.create(Run);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .app = undefined, .rounds = rounds, .sessions = load.sessions, .latency_ms = load.latency_ms, .image_bytes = load.image_bytes, .replies = &.{}, .corpus = &.{}, .progress = &.{} };
    var random: [16]u8 = undefined;
    host.io.random(&random);
    // The store makes this directory at its first image, so a text run never writes it.
    const blob_dir = try std.fmt.allocPrint(gpa, "/tmp/yuke-bench-blobs-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer gpa.free(blob_dir);
    try fixture.init(&self.app, gpa, host.io, blob_dir, .{ .ctx = self, .vtable = &.{ .open = open } }, host.execution);
    errdefer self.app.deinit();
    var local = try provider.config.loadBytes(gpa,
        \\{"providers":[{"id":"bench","base_url":"http://bench.invalid","endpoints":[{"protocol":"anthropic_messages"}],
        \\"models":[{"id":"m","upstream_id":"m","flags":{"supports_tools":true,"supports_vision":true},"limits":{"context_window":100000000,"max_output_tokens":32000}}]}]}
    );
    _ = self.app.store.installLocal(&local) catch |err| {
        local.deinit();
        return err;
    };
    self.app.engine.installTools(.{ .ctx = self, .decls = decls, .run = execute });
    self.corpus = try makeCorpus(gpa);
    errdefer gpa.free(self.corpus);
    self.replies = try makeReplies(gpa, rounds);
    errdefer {
        for (self.replies) |reply| gpa.free(reply);
        gpa.free(self.replies);
    }
    self.progress = try gpa.alloc(u32, load.sessions);
    // The SQLite high-water mark is global, so each run starts it again.
    var live: i64 = 0;
    var peak: i64 = 0;
    _ = zqlite.c.sqlite3_status64(zqlite.c.SQLITE_STATUS_MEMORY_USED, &live, &peak, 1);
    return self;
}

/// Free the App, the replies, and the corpus.
pub fn destroy(self: *Run) void {
    const gpa = self.gpa;
    std.Io.Dir.cwd().deleteTree(self.app.io, self.app.blob_dir) catch {}; // A failed delete leaves the directory in /tmp and does not fail the run.
    self.app.deinit();
    for (self.replies) |reply| gpa.free(reply);
    gpa.free(self.replies);
    gpa.free(self.corpus);
    gpa.free(self.progress);
    gpa.destroy(self);
}

/// Run each session from its first input to its final answer, then remove them, so each step starts from an empty store.
pub fn step(self: *Run) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    self.served = 0;
    self.last_body_bytes = 0;
    @memset(self.progress, 0);
    const ids = try a.alloc(proto.ids.SessionId, self.sessions);
    for (ids, 0..) |*id, i| {
        // `/bench` holds no AGENTS.md and no skills, so the prompt does not depend on the host.
        id.* = (try commands.sessionCreate(&self.app.engine, a, .{
            .workspace_path = "/bench",
            .model = "bench/m",
            .initial_input = .{ .content = .{ .content = &.{.{ .text = .{ .text = try std.fmt.allocPrint(a, "Read the corpus part by part. {s}{d}.", .{ session_tag, i }) } }} } },
        })).session.id;
    }
    try self.app.engine.turn_tasks.await(self.app.io);
    if (self.served != self.sessions * (self.rounds + 1)) return error.RunDidNotFinish;
    for (ids) |id| {
        // A failed request also ends the run, so only a stored final answer proves that every round ran.
        const last = (try store.message.historyPage(&self.app.db, a, id.raw, 0, 1)).messages;
        if (last.len != 1 or last[0] != .assistant or last[0].assistant.finish != .stop) return error.RunDidNotFinish;
        _ = try commands.sessionRemove(&self.app.engine, a, .{ .session_id = id });
    }
}

/// The live bytes and the high-water mark that SQLite holds outside the engine allocator. With the `:memory:` database, this includes the stored history.
pub fn sqliteBytes() struct { live: i64, peak: i64 } {
    var live: i64 = 0;
    var peak: i64 = 0;
    _ = zqlite.c.sqlite3_status64(zqlite.c.SQLITE_STATUS_MEMORY_USED, &live, &peak, 0);
    return .{ .live = live, .peak = peak };
}

/// Answer the next round of the session that sent `request`. Its first prompt names the session near the start of the body.
fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
    const self: *Run = @ptrCast(@alignCast(ctx));
    var len: usize = 0;
    var session: ?usize = null;
    for (request.body) |part| {
        len += part.len;
        if (session != null) continue;
        const near = part[0..@min(part.len, 64 * 1024)];
        const at = (std.mem.indexOf(u8, near, session_tag) orelse continue) + session_tag.len;
        session = std.fmt.parseInt(usize, near[at .. std.mem.indexOfScalarPos(u8, near, at, '.') orelse return error.UnexpectedRequest], 10) catch return error.UnexpectedRequest;
    }
    const round = &self.progress[session orelse return error.UnexpectedRequest];
    if (round.* > self.rounds) return error.UnexpectedRequest;
    if (self.latency_ms != 0) try self.app.io.sleep(.fromMilliseconds(self.latency_ms), .awake);
    self.last_body_bytes = @max(self.last_body_bytes, len);
    // The final request must carry one image for each tool round, or the phase measures no image.
    if (self.image_bytes != 0 and round.* == self.rounds) {
        var images: usize = 0;
        for (request.body) |part| images += std.mem.count(u8, part, "\"type\":\"image\"");
        if (images != self.rounds) return error.UnexpectedRequest;
    }
    const reader = try arena.create(ai.testing.ReplayReader);
    reader.* = .{ .bytes = if (round.* == self.rounds) ai.testing.canned_reply else self.replies[round.*] };
    round.* += 1;
    self.served += 1;
    return reader.body();
}

fn decls(_: *anyopaque, _: std.mem.Allocator) error{OutOfMemory}![]const toolset.Served {
    return &read_decl;
}

/// Answer a window of the corpus, and an image when the run asks for one. The window moves each round, so no two outputs are equal.
fn execute(ctx: *anyopaque, arena: std.mem.Allocator, _: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
    const self: *Run = @ptrCast(@alignCast(ctx));
    self.reads += 1;
    const start = (self.reads * 997) % (self.corpus.len - output_bytes);
    const output = self.corpus[start..][0..output_bytes];
    if (self.image_bytes == 0) return .{ .output = output };
    // An MCP tool answers its image as base64, and the engine stores it with `putBase64`.
    const image = arena.alloc(u8, self.image_bytes) catch @panic("out of memory");
    @memcpy(image[0..png_signature.len], png_signature);
    // The full round count keeps each image distinct, so the store writes every one.
    std.mem.writeInt(u32, image[png_signature.len..][0..4], self.reads, .little);
    @memset(image[png_signature.len + 4 ..], 0xa5);
    const encoder = std.base64.standard.Encoder;
    const text = encoder.encode(arena.alloc(u8, encoder.calcSize(image.len)) catch @panic("out of memory"), image);
    const blob = self.app.engine.deps.blobs.putBase64(self.app.io, arena, text) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory"),
        else => std.debug.panic("the bench image did not store: {t}", .{err}),
    };
    const media = arena.dupe(proto.content.MediaBlob, &.{blob}) catch @panic("out of memory");
    return .{ .output = output, .media = media };
}

/// Source-like lines, so the JSON escaping and the UTF-8 checks do real work.
fn makeCorpus(gpa: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var line: u32 = 1;
    while (out.written().len < 4 * output_bytes) : (line += 1)
        try out.writer.print("{d}: const value_{d} = try parse(\"field \\\"{d}\\\"\", .{{ .tab = '\\t' }});\n", .{ line, line, line });
    return out.toOwnedSlice();
}

/// Each tool round thinks with a signature, then calls `read`.
fn makeReplies(gpa: std.mem.Allocator, rounds: u32) ![]const []const u8 {
    const replies = try gpa.alloc([]const u8, rounds);
    var made: usize = 0;
    errdefer {
        for (replies[0..made]) |reply| gpa.free(reply);
        gpa.free(replies);
    }
    const signature: [signature_bytes]u8 = @splat('S');
    for (replies, 0..) |*reply, round| {
        reply.* = try std.fmt.allocPrint(gpa, frame("{{\"type\":\"message_start\",\"message\":{{\"usage\":{{\"input_tokens\":0}}}}}}") ++
            frame("{{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"thinking\",\"thinking\":\"\"}}}}") ++
            frame("{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"thinking_delta\",\"thinking\":\"Read part {d} next.\"}}}}") ++
            frame("{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"signature_delta\",\"signature\":\"{s}\"}}}}") ++
            frame("{{\"type\":\"content_block_stop\",\"index\":0}}") ++
            frame("{{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"toolu_{d}\",\"name\":\"read\"}}}}") ++
            frame("{{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"part\\\":{d}}}\"}}}}") ++
            frame("{{\"type\":\"content_block_stop\",\"index\":1}}") ++
            frame("{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":20}}}}") ++
            frame("{{\"type\":\"message_stop\"}}"), .{ round, &signature, round, round });
        made += 1;
    }
    return replies;
}
