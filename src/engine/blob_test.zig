//! These tests cover image put, admission, request build, and removal end to end.

const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const ai = @import("ai");
const database = @import("../store/store.zig");
const commands = @import("commands.zig");
const Resources = @import("test_resources.zig");
const Fixture = Resources.Fixture;
const toolset = @import("toolset.zig");
const blob_store = database.blob;

const png = blob_store.png_1x1;
const vision: ai.types.Modalities = .{ .input = &.{ .text, .image } };

/// Write an image under the blob test directory and put it. The path is absolute.
fn putImage(f: *Fixture, name: []const u8, data: []const u8) !proto.content.MediaBlob {
    try f.resources.blobs.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    const path = try std.fs.path.join(f.arena.allocator(), &.{ f.resources.blob_dir, name });
    return commands.blobPut(&f.engine, f.arena.allocator(), .{ .path = path });
}

test "initialize reports the blob store directory" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const result = try commands.initialize(&f.engine, f.arena.allocator());
    try testing.expectEqualStrings(f.resources.blob_dir, result.blob_dir);
}

test "a vision model receives the stored bytes and the transcript keeps only the ref" {
    var f: Fixture = undefined;
    try f.init(.{ .modalities = vision });
    defer f.deinit();
    const a = f.arena.allocator();

    const blob = try putImage(&f, "shot.png", png);
    const started = try f.send(&.{ .{ .text = .{ .text = "what is this" } }, .{ .image = .{ .source = blob } } });
    try testing.expect(started == .started);
    try f.finish(Fixture.id);

    try testing.expectEqual(@as(usize, 1), f.capture.requests.items.len);
    const body = f.capture.requests.items[0];
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
    try f.init(.{ .modalities = .{ .input = &.{.text} } });
    defer f.deinit();

    const blob = try putImage(&f, "shot.png", png);
    try f.resources.blobs.dir.deleteFile(testing.io, "shot.png");
    _ = try f.send(&.{.{ .image = .{ .source = blob } }});
    try f.finish(Fixture.id);
    try testing.expectEqual(@as(usize, 1), f.capture.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, f.capture.requests.items[0], "[image omitted: this model reads no images]") != null);
    try testing.expect(std.mem.indexOf(u8, f.capture.requests.items[0], "\"type\":\"image\"") == null);
}

test "a ref the store cannot vouch for never commits" {
    var f: Fixture = undefined;
    try f.init(.{ .modalities = vision, .replies = &.{} });
    defer f.deinit();
    const a = f.arena.allocator();

    const unknown: proto.content.MediaBlob = .{ .hash = .bytes(@splat(0x5a)), .mime = "image/png", .bytes = png.len };
    try testing.expectError(error.BlobMissing, f.send(&.{.{ .image = .{ .source = unknown } }}));
    var lies = try putImage(&f, "shot.png", png);
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

/// A tool that answers one image ref, so a test can name bytes the store holds or lacks.
const ImageTool = struct {
    media: [1]proto.content.MediaBlob,

    fn run(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: toolset.Context) toolset.Outcome {
        const self: *ImageTool = @ptrCast(@alignCast(raw));
        return .{ .output = "PNG image, 67 B", .media = &self.media, .is_error = false };
    }
};

test "a tool image commits as media with a ref, and a ref the store lacks becomes a tool error" {
    var f: Fixture = undefined;
    try f.init(.{ .modalities = vision, .replies = &.{ Resources.tool_reply, ai.transport.canned_reply, Resources.tool_reply, ai.transport.canned_reply } });
    defer f.deinit();
    const a = f.arena.allocator();
    const blob = try putImage(&f, "shot.png", png);
    var tool: ImageTool = .{ .media = .{blob} };
    f.engine.installTools(.{ .ctx = &tool, .run = ImageTool.run });

    _ = try f.send(&.{.{ .text = .{ .text = "look" } }});
    try f.finish(Fixture.id);
    // Each round commits one assistant message: the tool round, then the answer.
    var messages = try f.history();
    try testing.expectEqual(@as(usize, 3), messages.len);
    const part = messages[1].assistant.content[0].tool;
    try testing.expectEqualSlices(u8, &blob.hash.raw, &part.state.completed.media.?[0].hash.raw);
    // No user message names the blob, so the tool part alone keeps the ref alive.
    try testing.expect(try blob_store.referenced(&f.db, a, blob.hash));
    {
        const row = (try f.db.conn.row("SELECT images FROM messages WHERE message_id = 2", .{})).?;
        defer row.deinit();
        try testing.expectEqual(@as(i64, 1), row.int(0));
    }

    tool.media[0].hash = .bytes(@splat(0x5a));
    _ = try f.send(&.{.{ .text = .{ .text = "again" } }});
    try f.finish(Fixture.id);
    messages = try f.history();
    try testing.expectEqual(@as(usize, 6), messages.len);
    const refused = messages[4].assistant.content[0].tool;
    try testing.expect(refused.state == .@"error");
    try testing.expect(std.mem.indexOf(u8, refused.state.@"error".@"error", "does not hold") != null);

    _ = try commands.sessionRemove(&f.engine, a, .{ .session_id = Fixture.id });
    try testing.expectError(error.BlobMissing, f.engine.deps.blobs.read(f.engine.deps.io, a, blob.hash));
}

test "removing the last session that names a blob unlinks it" {
    var f: Fixture = undefined;
    try f.init(.{ .modalities = vision, .replies = &.{ ai.transport.canned_reply, ai.transport.canned_reply } });
    defer f.deinit();
    const a = f.arena.allocator();

    const blob = try putImage(&f, "shot.png", png);
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

test "a blob sync failure rejects input and converts tool media into an error" {
    const Fail = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    };
    var f: Fixture = undefined;
    try f.init(.{ .replies = &.{ Resources.tool_reply, ai.transport.canned_reply } });
    defer f.deinit();
    const blob = try putImage(&f, "shot.png", png);
    const original = f.engine.deps.io;
    var vtable = original.vtable.*;
    vtable.fileSync = Fail.sync;
    f.engine.deps.io.vtable = &vtable;
    defer f.engine.deps.io = original;
    try testing.expectError(error.BlobStoreFailed, f.send(&.{.{ .image = .{ .source = blob } }}));
    try testing.expect(f.gate == null);
    try testing.expectEqual(@as(usize, 0), (try f.history()).len);
    try testing.expectEqual(@as(u64, 0), try database.input.count(&f.db, f.arena.allocator(), Fixture.id.raw));
    try testing.expect(!try blob_store.referenced(&f.db, f.arena.allocator(), blob.hash));
    var tool: ImageTool = .{ .media = .{blob} };
    f.engine.installTools(.{ .ctx = &tool, .run = ImageTool.run });
    _ = try f.send(&.{.{ .text = .{ .text = "look" } }});
    try f.finish(Fixture.id);
    const messages = try f.history();
    const refused = messages[1].assistant.content[0].tool;
    try testing.expect(refused.state == .@"error");
    try testing.expectEqualStrings("The engine could not persist the tool image.", refused.state.@"error".@"error");
    try testing.expect(!try blob_store.referenced(&f.db, f.arena.allocator(), blob.hash));
}
