//! These tests cover image put, admission, request build, and removal end to end.

const std = @import("std");
const testing = std.testing;
const proto = @import("proto");
const ai = @import("ai");
const database = @import("../store/store.zig");
const commands = @import("commands.zig");
const Fixture = @import("test_resources.zig").Fixture;
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
