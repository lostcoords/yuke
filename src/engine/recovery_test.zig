//! Ownership and recovery tests use independent connections to one database.

const std = @import("std");
const zqlite = @import("zqlite");
const proto = @import("proto");
const database = @import("../store/store.zig");
const Engine = @import("Engine.zig");
const commands = @import("commands.zig");
const turn = @import("turn.zig");
const run = @import("run.zig");
const testing = std.testing;
const Resources = @import("test_resources.zig");

const Fixture = struct {
    tmp: testing.TmpDir,
    resources: Resources,
    db: database.Database,
    other_db: database.Database,
    engine: Engine,
    other: Engine,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.resources.init();
        errdefer self.resources.deinit();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)];
        const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/yuke.db", .{root}, 0);
        defer testing.allocator.free(path);
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex | zqlite.OpenFlags.EXResCode;
        self.db = try database.Database.open(try zqlite.open(path, flags));
        errdefer self.db.deinit();
        self.other_db = try database.Database.open(try zqlite.open(path, flags));
        self.engine = self.resources.makeEngine(&self.db);
        self.other = self.resources.makeEngine(&self.other_db);
    }

    fn deinit(self: *Fixture) void {
        self.other.close();
        self.engine.close();
        self.other_db.deinit();
        self.db.deinit();
        self.resources.deinit();
        self.tmp.cleanup();
    }
};

fn seed(db: *database.Database, id: [16]u8, parent: ?[16]u8, workspace: []const u8) !void {
    try database.session.create(db, .{
        .id = id,
        .root = workspace,
        .origin = if (parent != null) "child" else "root",
        .parent_id = parent,
        .parent_message_id = if (parent != null) 1 else null,
        .parent_part_id = if (parent != null) 0 else null,
        .name = if (parent != null) "child" else null,
        .profile = "default",
        .model = "test/model",
        .reasoning = "",
        .config_rev = 0,
        .title = "test",
        .created_at_ms = 1,
        .updated_at_ms = 1,
    });
}

fn start(db: *database.Database, io: std.Io, arena: std.mem.Allocator, id: [16]u8) !void {
    _ = try run.beginTurn(db, io, arena, id, .{ .content = &.{.{ .text = .{ .text = "committed input" } }} }, 0);
}

/// A wake runs on the executor; wait until that run committed its terminal.
fn awaitIdle(f: *Fixture, arena: std.mem.Allocator, id: [16]u8, run_id: u64) !void {
    for (0..1000) |_| {
        const marks = (try database.event.highWater(&f.db, arena, id)).?;
        if (marks.run_id_high >= run_id and (try database.session.snapshot(&f.db, arena, id)).?.open_run_id == null) return;
        try std.Io.sleep(f.resources.runtime.io(), .fromMilliseconds(1), .awake);
    }
    return error.RunDidNotFinish;
}

fn queued(db: *database.Database, arena: std.mem.Allocator, id: [16]u8) !void {
    var tx = try db.begin();
    defer tx.deinit();
    const event_id = @import("../util.zig").newId(testing.io);
    _ = try database.input.enqueue(db, arena, id, event_id, 2, .{ .content = &.{.{ .text = .{ .text = "queued input" } }} }, 2);
    try tx.commit();
}

test "skill input survives admission teardown and recovery through another connection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const sid = [_]u8{91} ** 16;
    const text = "<skill_content name=\"pdf\">\nExact </skill_content> & body.\n</skill_content>\n\nreport.pdf";
    try seed(&f.db, sid, null, "/work");
    {
        var admission: std.heap.ArenaAllocator = .init(testing.allocator);
        defer admission.deinit();
        var tx = try f.db.begin();
        defer tx.deinit();
        _ = try database.input.enqueue(&f.db, admission.allocator(), sid, [_]u8{92} ** 16, 2, .{
            .content = &.{.{ .text = .{ .text = text } }},
            .skill_name = "pdf",
        }, 2);
        try tx.commit();
    }
    const resident = try f.other.activate(.bytes(sid));
    try testing.expectEqualStrings("pdf", resident.queueEntries()[0].skill_name.?);
    try testing.expectEqualStrings(text, resident.queueEntries()[0].content[0].text.text);
    {
        var admission: std.heap.ArenaAllocator = .init(testing.allocator);
        defer admission.deinit();
        _ = try run.beginQueuedTurn(&f.other_db, f.resources.runtime.io(), admission.allocator(), sid, 0);
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try database.message.historyPage(&f.db, arena.allocator(), sid, 0, 10);
    try testing.expectEqual(@as(usize, 1), page.messages.len);
    try testing.expectEqualStrings("pdf", page.messages[0].user.skill_name.?);
    try testing.expectEqualStrings(text, page.messages[0].user.content[0].text.text);
    const projected = try @import("context.zig").project(arena.allocator(), &f.db, sid, .{}, .{ .max_tokens = 10_000, .input_ceiling = 40_000 });
    try testing.expectEqualStrings("pdf", projected.messages[0].user.skill_name.?);
    try testing.expectEqualStrings(text, projected.messages[0].user.content[0].text.text);
}

test "repair wakes an idle intermediate parent after a grandchild interruption" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const root = [_]u8{1} ** 16;
    const child = [_]u8{2} ** 16;
    const grandchild = [_]u8{3} ** 16;
    try seed(&f.db, root, null, "/work");
    try seed(&f.db, child, root, "/work");
    try seed(&f.db, grandchild, child, "/work");
    try start(&f.db, f.resources.runtime.io(), a, grandchild);
    try f.engine.own(.bytes(root));
    try awaitIdle(&f, a, child, 1);
    try awaitIdle(&f, a, root, 1);
    const history = try database.message.historyPage(&f.db, a, child, 0, 10);
    try testing.expectEqualStrings("child", history.messages[0].user.source.?.child_report.name);
    try testing.expectEqual(proto.enums.RunErrorCode.interrupted, history.messages[0].user.source.?.child_report.outcome.failed.code);
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, grandchild)).?.run_id_high);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, child));
}

test "tree ownership protects live runs and repair preserves committed input" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const root = [_]u8{1} ** 16;
    const child = [_]u8{2} ** 16;
    const independent = [_]u8{3} ** 16;
    try seed(&f.db, root, null, "/work");
    try seed(&f.db, child, root, "/work");
    try seed(&f.db, independent, null, "/elsewhere");
    try f.engine.own(.bytes(root));
    try f.other.own(.bytes(independent));
    try start(&f.db, f.resources.runtime.io(), a, root);
    try start(&f.db, f.resources.runtime.io(), a, child);
    const stale = try f.other.activate(.bytes(root));
    stale.pin();
    try queued(&f.db, a, root);
    try testing.expectEqual(@as(usize, 0), stale.queueDepth());
    try testing.expectError(error.SessionOwned, f.other.own(.bytes(child)));
    try testing.expectError(error.SessionOwned, commands.sessionRemove(&f.other, a, .{ .session_id = .bytes(child) }));
    const history = try commands.sessionHistory(&f.other, a, .{ .session_id = .bytes(root), .before_message_id = 999 });
    try testing.expect(history.messages.len == 1);
    try testing.expectEqual(@as(?u64, 1), (try database.session.snapshot(&f.db, a, root)).?.open_run_id);

    f.engine.close();
    f.engine = f.resources.makeEngine(&f.db);
    try f.other.own(.bytes(child));
    // The repair wakes the root on the executor: run 2 takes the queued input and the child report.
    try awaitIdle(&f, a, root, 2);
    try testing.expect((try database.session.snapshot(&f.db, a, child)).?.open_run_id == null);
    try testing.expectEqual(@as(u32, 1), stale.pins);
    try testing.expectEqual(@as(usize, 0), stale.queueDepth());
    const before = (try database.event.highWater(&f.db, a, root)).?.seq_high;
    try f.other.own(.bytes(root));
    try testing.expectEqual(before, (try database.event.highWater(&f.db, a, root)).?.seq_high);
    const row = (try f.db.conn.row("SELECT payload FROM events WHERE session_id = ?1 AND name = 'run.done' ORDER BY seq LIMIT 1", .{zqlite.blob(&root)})).?;
    defer row.deinit();
    const done = try std.json.parseFromSliceLeaky(proto.run.RunDoneData, a, row.text(0), .{});
    try testing.expectEqual(proto.enums.RunErrorCode.interrupted, done.outcome.failed.code);
    try testing.expectEqual(@as(u64, 1), done.run_id);
    const after = try database.message.historyPage(&f.db, a, root, 0, 10);
    var promoted = false;
    for (after.messages) |m| if (m == .user and m.user.source == null and std.mem.eql(u8, m.user.content[0].text.text, "queued input")) {
        promoted = true;
    };
    try testing.expect(promoted);
    stale.unpin();

    var launch: ?turn.Launch = null;
    const result = try commands.sessionSendInputForRpc(&f.other, a, .{
        .session_id = .bytes(child),
        .input = .{ .content = .{ .content = &.{.{ .text = .{ .text = "continue" } }} } },
    }, &launch, null);
    try testing.expectEqual(@as(u64, 2), result.started.run_id);
    turn.Launch.release(&launch, &f.other);
    f.other.stopTurns();
}

test "workspace resume waits for explicit startup and skips another owner's tree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const idle = [_]u8{4} ** 16;
    const busy = [_]u8{5} ** 16;
    const other_workspace = [_]u8{6} ** 16;
    for ([_][16]u8{ idle, busy, other_workspace }) |id| {
        try seed(&f.db, id, null, if (std.mem.eql(u8, &id, &other_workspace)) "/other" else "/work");
        try queued(&f.db, a, id);
    }
    try f.other.own(.bytes(busy));
    _ = try f.engine.activate(.bytes(idle));
    _ = try commands.sessionList(&f.engine, a, .{});
    try testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, idle));
    try testing.expect((try database.session.snapshot(&f.db, a, idle)).?.open_run_id == null);
    try f.engine.resumeWorkspace("/work");
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, a, idle));
    try testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, busy));
    try testing.expectEqual(@as(u64, 1), try database.input.count(&f.db, a, other_workspace));
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, idle)).?.run_id_high);
    try f.engine.resumeWorkspace("/work");
    try testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.db, a, idle)).?.run_id_high);
    f.engine.stopTurns();
    try testing.expectError(error.EngineClosing, f.engine.resumeWorkspace("/work"));
    try testing.expectError(error.EngineClosing, f.engine.own(.bytes(other_workspace)));
}

test "root removal releases only its tree claim" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const root = [_]u8{1} ** 16;
    const child = [_]u8{2} ** 16;
    try seed(&f.db, root, null, "/work");
    try seed(&f.db, child, root, "/work");
    _ = try commands.sessionRemove(&f.engine, a, .{ .session_id = .bytes(child) });
    try testing.expect(f.engine.owners.contains(root));
    try testing.expectError(error.SessionOwned, f.other.own(.bytes(root)));
    _ = try commands.sessionRemove(&f.engine, a, .{ .session_id = .bytes(root) });
    try testing.expectEqual(@as(u32, 0), f.engine.owners.count());
    const guard = try @import("ownership.zig").acquire(testing.allocator, f.resources.runtime.io(), &f.other_db, root);
    defer guard.release(f.resources.runtime.io());
}
