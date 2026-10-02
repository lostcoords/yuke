//! One long agent run drives the production engine, store, and request path with no network.

const std = @import("std");
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
const read_decl = [_]ai.ir.Tool{.{ .name = "read", .description = "Read a part of the corpus.", .input_schema = "{\"type\":\"object\",\"properties\":{\"part\":{\"type\":\"integer\"}},\"required\":[\"part\"]}" }};

gpa: std.mem.Allocator,
app: App,
rounds: u32,
/// The tool rounds of one run. The final text answer is `ai.testing.canned_reply`.
replies: []const []const u8,
/// The text that the tool answers. Each round reads another window of it.
corpus: []const u8,
served: u32 = 0,
/// The body size of the newest request, so a report can relate memory to the history size.
last_body_bytes: usize = 0,

/// Own one App on an in-memory database, the canned replies, and the corpus. It fails on OOM or a store error.
pub fn create(host: *Host, rounds: u32) !*Run {
    std.debug.assert(rounds > 0);
    const gpa = host.gpa;
    const self = try gpa.create(Run);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .app = undefined, .rounds = rounds, .replies = &.{}, .corpus = &.{} };
    // The run admits no media, so the blob store never writes this directory.
    try fixture.init(&self.app, gpa, host.io, "/bench/blobs", .{ .ctx = self, .vtable = &.{ .open = open } }, host.execution);
    errdefer self.app.deinit();
    var local = try provider.config.loadBytes(gpa,
        \\{"providers":[{"id":"bench","base_url":"http://bench.invalid","endpoints":[{"protocol":"anthropic_messages"}],
        \\"models":[{"id":"m","upstream_id":"m","flags":{"supports_tools":true},"limits":{"context_window":100000000,"max_output_tokens":32000}}]}]}
    );
    _ = self.app.store.installLocal(&local) catch |err| {
        local.deinit();
        return err;
    };
    self.app.engine.installTools(.{ .ctx = self, .decls = decls, .run = execute });
    self.corpus = try makeCorpus(gpa);
    errdefer gpa.free(self.corpus);
    self.replies = try makeReplies(gpa, rounds);
    // The SQLite high-water mark is global, so each run starts it again.
    var live: i64 = 0;
    var peak: i64 = 0;
    _ = zqlite.c.sqlite3_status64(zqlite.c.SQLITE_STATUS_MEMORY_USED, &live, &peak, 1);
    return self;
}

/// Free the App, the replies, and the corpus.
pub fn destroy(self: *Run) void {
    const gpa = self.gpa;
    self.app.deinit();
    for (self.replies) |reply| gpa.free(reply);
    gpa.free(self.replies);
    gpa.free(self.corpus);
    gpa.destroy(self);
}

/// Run one session from its first input to its final answer, then remove it, so each step starts from an empty store.
pub fn step(self: *Run) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    self.served = 0;
    // `/bench` holds no AGENTS.md and no skills, so the prompt does not depend on the host.
    const created = try commands.sessionCreate(&self.app.engine, a, .{
        .workspace_path = "/bench",
        .model = "bench/m",
        .initial_input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "Read the corpus part by part." } }} } },
    });
    try self.app.engine.turn_tasks.await(self.app.io);
    const sid = created.session.id;
    // A failed request also ends the run, so only a stored final answer proves that every round ran.
    const last = (try store.message.historyPage(&self.app.db, a, sid.raw, 0, 1)).messages;
    if (self.served != self.rounds + 1 or last.len != 1 or last[0] != .assistant or last[0].assistant.finish != .stop) return error.RunDidNotFinish;
    _ = try commands.sessionRemove(&self.app.engine, a, .{ .session_id = sid });
}

/// The live bytes and the high-water mark that SQLite holds outside the engine allocator. With the `:memory:` database, this includes the stored history.
pub fn sqliteBytes() struct { live: i64, peak: i64 } {
    var live: i64 = 0;
    var peak: i64 = 0;
    _ = zqlite.c.sqlite3_status64(zqlite.c.SQLITE_STATUS_MEMORY_USED, &live, &peak, 0);
    return .{ .live = live, .peak = peak };
}

fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
    const self: *Run = @ptrCast(@alignCast(ctx));
    if (self.served > self.rounds) return error.UnexpectedRequest;
    self.last_body_bytes = 0;
    for (request.body) |part| self.last_body_bytes += part.len;
    const reader = try arena.create(ai.testing.ReplayReader);
    reader.* = .{ .bytes = if (self.served == self.rounds) ai.testing.canned_reply else self.replies[self.served] };
    self.served += 1;
    return reader.body();
}

fn decls(_: *anyopaque, _: std.mem.Allocator) error{OutOfMemory}![]const ai.ir.Tool {
    return &read_decl;
}

/// Answer a window of the corpus. The window moves each round, so no two outputs are equal.
fn execute(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
    const self: *Run = @ptrCast(@alignCast(ctx));
    std.debug.assert(self.served > 0);
    const start = (self.served * 997) % (self.corpus.len - output_bytes);
    return .{ .output = self.corpus[start..][0..output_bytes] };
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
