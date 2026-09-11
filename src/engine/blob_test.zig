//! These tests cover image put, admission, request build, and removal end to end.

const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const database = @import("../store/store.zig");
const commands = @import("commands.zig");
const turn = @import("turn.zig");
const Resources = @import("test_resources.zig");
const registry = @import("../provider/registry.zig");
const blob_store = database.blob;

const Fixture = struct {
    resources: Resources,
    db: database.Database,
    engine: Engine,
    arena: std.heap.ArenaAllocator,
    models: [1]registry.ModelSpec,
    rows: [1]registry.Provider,
    requests: std.ArrayList([]const u8) = .empty,
    gate: ?turn.Launch = null,

    const id: proto.ids.SessionId = .bytes([_]u8{74} ** 16);

    fn init(self: *Fixture, input: []const ai.types.Modality) !void {
        self.* = .{ .resources = undefined, .db = undefined, .engine = undefined, .arena = .init(testing.allocator), .models = undefined, .rows = undefined };
        try self.resources.init();
        self.db = try database.Database.openTest();
        self.engine = self.resources.makeEngine(&self.db);
        self.models = .{.{ .id = "m", .upstream_id = "m", .name = "M", .caps = .{ .tools = true }, .modalities = .{ .input = input } }};
        self.rows = .{.{ .id = "mock", .name = "Mock", .models = &self.models, .availability = .{ .ready = .{
            .route = .{ .base_url = "https://example.test", .protocol = .anthropic_messages, .auth = .none },
            .credential = .none,
        } } }};
        self.resources.providers.merged.rows = &self.rows;
        self.engine.deps.route_transport = .{ .ctx = self, .vtable = &.{ .open = open } };
        try database.session.create(&self.db, .{ .id = id.raw, .root = "/work", .origin = "root", .profile = "default", .model = "mock/m", .reasoning = "", .config_rev = 0, .title = "test", .created_at_ms = 1, .updated_at_ms = 1 });
        _ = try database.session.setPrompt(&self.db, self.arena.allocator(), id.raw, .{ .base = "", .child_policy = null, .environment = "" });
    }

    fn deinit(self: *Fixture) void {
        self.engine.close();
        self.resources.providers.merged.rows = &.{};
        self.db.deinit();
        self.resources.deinit();
        self.arena.deinit();
    }

    /// Write an image under the blob test directory and put it. The path is absolute.
    fn putImage(self: *Fixture, name: []const u8, data: []const u8) !proto.content.MediaBlob {
        try self.resources.blobs.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        const path = try std.fs.path.join(self.arena.allocator(), &.{ self.resources.blob_dir, name });
        return commands.blobPut(&self.engine, self.arena.allocator(), .{ .path = path });
    }

    fn send(self: *Fixture, content: []const proto.content.ContentPart) !proto.session.SessionSendInputResult {
        return commands.sessionSendInputForRpc(&self.engine, self.arena.allocator(), .{ .session_id = id, .input = .{ .content = .{ .content = content } } }, &self.gate, null);
    }

    /// Start the launched run and wait until the session is idle again.
    fn finish(self: *Fixture, session: proto.ids.SessionId) !void {
        turn.Launch.release(&self.gate, &self.engine);
        for (0..1000) |_| {
            const resident = self.engine.sessions.get(session);
            if (resident == null or (resident.?.active_run == null and resident.?.queueDepth() == 0)) return;
            try std.Io.sleep(self.engine.deps.io, .fromMilliseconds(1), .awake);
        }
        return error.RunDidNotFinish;
    }

    fn history(self: *Fixture) ![]const proto.message.Message {
        return (try database.message.historyPage(&self.db, self.arena.allocator(), id.raw, 0, 100)).messages;
    }

    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: ai.transport.Request, _: *ai.transport.AttemptInfo) !ai.transport.ResponseBody {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        try self.requests.append(self.arena.allocator(), try self.arena.allocator().dupe(u8, request.body));
        const reader = try arena.create(ai.transport.ReplayReader);
        reader.* = .{ .bytes = ai.transport.canned_reply };
        return reader.body();
    }
};

const png = blob_store.png_1x1;

test "initialize reports the blob store directory" {
    var f: Fixture = undefined;
    try f.init(&.{ .text, .image });
    defer f.deinit();
    const result = try commands.initialize(&f.engine, f.arena.allocator());
    try testing.expectEqualStrings(f.resources.blob_dir, result.blob_dir);
}

test "a vision model receives the stored bytes and the transcript keeps only the ref" {
    var f: Fixture = undefined;
    try f.init(&.{ .text, .image });
    defer f.deinit();
    const a = f.arena.allocator();

    const blob = try f.putImage("shot.png", png);
    const started = try f.send(&.{ .{ .text = .{ .text = "what is this" } }, .{ .image = .{ .source = blob } } });
    try testing.expect(started == .started);
    try f.finish(Fixture.id);

    try testing.expectEqual(@as(usize, 1), f.requests.items.len);
    const body = f.requests.items[0];
    var expected: [std.base64.standard.Encoder.calcSize(png.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&expected, png);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, &expected) != null);

    const messages = try f.history();
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expectEqualSlices(u8, &blob.hash.raw, &messages[0].user.content[1].image.source.hash.raw);
    const stored = try std.json.Stringify.valueAlloc(a, messages[0], .{});
    try testing.expect(std.mem.indexOf(u8, stored, &expected) == null); // The log holds the ref, never the pixels.
    try testing.expect(try blob_store.referenced(&f.db, a, blob.hash));
}

test "a text-only model receives the omission note and the store is never read" {
    var f: Fixture = undefined;
    try f.init(&.{.text});
    defer f.deinit();

    const blob = try f.putImage("shot.png", png);
    try f.resources.blobs.dir.deleteFile(testing.io, "shot.png");
    _ = try f.send(&.{.{ .image = .{ .source = blob } }});
    try f.finish(Fixture.id);
    try testing.expectEqual(@as(usize, 1), f.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[0], "[image omitted: this model reads no images]") != null);
    try testing.expect(std.mem.indexOf(u8, f.requests.items[0], "\"type\":\"image\"") == null);
}

test "a ref the store cannot vouch for never commits" {
    var f: Fixture = undefined;
    try f.init(&.{ .text, .image });
    defer f.deinit();
    const a = f.arena.allocator();

    const unknown: proto.content.MediaBlob = .{ .hash = .bytes(@splat(0x5a)), .mime = "image/png", .bytes = png.len };
    try testing.expectError(error.BlobMissing, f.send(&.{.{ .image = .{ .source = unknown } }}));
    var lies = try f.putImage("shot.png", png);
    lies.mime = "image/gif";
    try testing.expectError(error.BlobMismatch, f.send(&.{.{ .image = .{ .source = lies } }}));
    try testing.expect(f.gate == null);
    try testing.expectEqual(@as(usize, 0), (try f.history()).len);
    try testing.expectEqual(@as(usize, 0), (try blob_store.refsOf(&f.db, a, Fixture.id.raw)).len);

    // A draft that attaches before the session exists goes through session.create, which admits the same way.
    const before = try database.session.count(&f.db, a, .{});
    try testing.expectError(error.BlobMissing, commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "mock/m", .initial_input = .{ .content = .{ .content = &.{.{ .image = .{ .source = unknown } }} } } }));
    try testing.expectEqual(before, try database.session.count(&f.db, a, .{}));
}

test "removing the last session that names a blob unlinks it" {
    var f: Fixture = undefined;
    try f.init(&.{ .text, .image });
    defer f.deinit();
    const a = f.arena.allocator();

    const blob = try f.putImage("shot.png", png);
    _ = try f.send(&.{.{ .image = .{ .source = blob } }});
    try f.finish(Fixture.id);

    // A second session shares the blob, so the first removal must keep the file.
    const other = try commands.sessionCreate(&f.engine, a, .{ .workspace_path = "/work", .model = "mock/m", .initial_input = .{ .content = .{ .content = &.{.{ .image = .{ .source = blob } }} } } });
    try f.finish(other.session.id);
    _ = try commands.sessionRemove(&f.engine, a, .{ .session_id = Fixture.id });
    _ = try f.engine.deps.blobs.read(f.engine.deps.io, a, blob.hash);

    _ = try commands.sessionRemove(&f.engine, a, .{ .session_id = other.session.id });
    try testing.expectError(error.BlobMissing, f.engine.deps.blobs.read(f.engine.deps.io, a, blob.hash));
}
