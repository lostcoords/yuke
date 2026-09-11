//! The store keeps image bytes on disk by hash. The refs table lets a removal unlink an unused blob.

const std = @import("std");
const sql = @import("sql");
const zqlite = @import("zqlite");
const proto = @import("proto");

const Database = @import("store.zig").Database;

pub const MediaBlob = proto.content.MediaBlob;
pub const Hash = proto.ids.BlobHash;

/// A put accepts at most 7 MiB, which is 9.33 MiB of base64 under the Anthropic 10 MB per-image limit.
pub const max_bytes: u64 = proto.meta.limits.max_blob_bytes;
/// One input carries at most this many image parts.
pub const max_images_per_input: usize = proto.meta.limits.max_input_images;
/// A sniff reads 12 bytes, because the WebP magic number is the longest.
const sniff_bytes = 12;

pub const PutError = error{
    BlobPathNotAbsolute,
    BlobUnreadable,
    BlobNotRegularFile,
    BlobEmpty,
    BlobTooLarge,
    BlobUnsupportedType,
    BlobStoreFailed,
    OutOfMemory,
    Canceled,
};

pub const AdmitError = error{
    BlobMissing,
    BlobMismatch,
    BlobTooManyImages,
    BlobUnsupportedPart,
    OutOfMemory,
    Canceled,
};

/// The store borrows one directory path. A blob lives at `<dir>/<64 hex>`.
pub const Store = struct {
    dir: []const u8,

    /// Copy the file at `path` into the store and describe it. A second put of the same bytes is a no-op.
    pub fn put(self: Store, io: std.Io, arena: std.mem.Allocator, path: []const u8) PutError!MediaBlob {
        std.debug.assert(self.dir.len != 0);
        if (!std.fs.path.isAbsolute(path)) return error.BlobPathNotAbsolute;
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobUnreadable,
        };
        if (stat.kind != .file) return error.BlobNotRegularFile;
        if (stat.size == 0) return error.BlobEmpty;
        if (stat.size > max_bytes) return error.BlobTooLarge;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes + 1)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            error.StreamTooLong => return error.BlobTooLarge,
            else => return error.BlobUnreadable,
        };
        if (data.len == 0) return error.BlobEmpty;
        const mime = sniff(data) orelse return error.BlobUnsupportedType;

        var digest: [Hash.byte_len]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const blob: MediaBlob = .{ .hash = .bytes(digest), .mime = mime, .bytes = data.len };
        const target = try self.pathOf(arena, blob.hash);
        if (self.exists(io, target)) return blob;
        try self.write(io, arena, target, data);
        return blob;
    }

    /// Refuse an input whose media parts name bytes the store does not hold as described.
    pub fn admit(self: Store, io: std.Io, arena: std.mem.Allocator, content: []const proto.content.ContentPart) AdmitError!void {
        std.debug.assert(self.dir.len != 0);
        var images: usize = 0;
        for (content) |part| switch (part) {
            .text => {},
            .image => |image| {
                images += 1;
                if (images > max_images_per_input) return error.BlobTooManyImages;
                try self.verify(io, arena, image.source);
            },
            .audio, .file => return error.BlobUnsupportedPart,
        };
    }

    /// Read one stored blob. The caller admitted the ref, so an absent file is a corrupt store.
    pub fn read(self: Store, io: std.Io, arena: std.mem.Allocator, hash: Hash) error{ OutOfMemory, Canceled, BlobMissing }![]const u8 {
        std.debug.assert(self.dir.len != 0);
        const target = try self.pathOf(arena, hash);
        return std.Io.Dir.cwd().readFileAlloc(io, target, arena, .limited(max_bytes + 1)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            else => return error.BlobMissing,
        };
    }

    /// Delete one stored blob. An absent file is already the wanted state.
    pub fn unlink(self: Store, io: std.Io, arena: std.mem.Allocator, hash: Hash) error{ OutOfMemory, Canceled, BlobStoreFailed }!void {
        std.debug.assert(self.dir.len != 0);
        const target = try self.pathOf(arena, hash);
        std.Io.Dir.deleteFileAbsolute(io, target) catch |err| switch (err) {
            error.FileNotFound => {},
            error.Canceled => return error.Canceled,
            else => return error.BlobStoreFailed,
        };
    }

    fn verify(self: Store, io: std.Io, arena: std.mem.Allocator, blob: MediaBlob) AdmitError!void {
        const target = try self.pathOf(arena, blob.hash);
        const file = std.Io.Dir.openFileAbsolute(io, target, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobMissing,
        };
        defer file.close(io);
        const stat = file.stat(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobMissing,
        };
        if (stat.size != blob.bytes) return error.BlobMismatch;
        var head: [sniff_bytes]u8 = undefined;
        const n = file.readPositionalAll(io, &head, 0) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobMissing,
        };
        const mime = sniff(head[0..n]) orelse return error.BlobMismatch;
        if (!std.mem.eql(u8, mime, blob.mime)) return error.BlobMismatch;
    }

    fn pathOf(self: Store, arena: std.mem.Allocator, hash: Hash) error{OutOfMemory}![]const u8 {
        const hex = std.fmt.bytesToHex(hash.raw, .lower);
        return std.fs.path.join(arena, &.{ self.dir, &hex });
    }

    fn exists(self: Store, io: std.Io, target: []const u8) bool {
        std.debug.assert(std.mem.startsWith(u8, target, self.dir));
        std.Io.Dir.accessAbsolute(io, target, .{}) catch return false;
        return true;
    }

    /// Write to a temp name and rename, so a crash never leaves partial bytes under a valid hash.
    fn write(self: Store, io: std.Io, arena: std.mem.Allocator, target: []const u8, data: []const u8) PutError!void {
        std.debug.assert(data.len != 0 and data.len <= max_bytes);
        std.Io.Dir.cwd().createDirPath(io, self.dir) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobStoreFailed,
        };
        var nonce: [8]u8 = undefined;
        io.random(&nonce);
        const temp = try std.fmt.allocPrint(arena, "{s}{c}.put-{x}", .{ self.dir, std.fs.path.sep, &nonce });
        const file = std.Io.Dir.createFileAbsolute(io, temp, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobStoreFailed,
        };
        errdefer std.Io.Dir.deleteFileAbsolute(io, temp) catch {};
        {
            defer file.close(io);
            file.writePositionalAll(io, data, 0) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.BlobStoreFailed,
            };
        }
        std.Io.Dir.renameAbsolute(temp, target, io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.BlobStoreFailed,
        };
    }
};

/// Name the image type from the magic bytes, or null for anything the store does not accept.
pub fn sniff(head: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, head, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, head, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, head, "GIF87a") or std.mem.startsWith(u8, head, "GIF89a")) return "image/gif";
    if (head.len >= sniff_bytes and std.mem.eql(u8, head[0..4], "RIFF") and std.mem.eql(u8, head[8..12], "WEBP")) return "image/webp";
    return null;
}

/// Record each blob a stored input names, in the caller's transaction. A duplicate has no effect.
pub fn recordRefs(db: *Database, session_id: [16]u8, content: []const proto.content.ContentPart) !void {
    std.debug.assert(sql.inTransaction(db.conn));
    for (content) |part| {
        const blob = switch (part) {
            .text => continue,
            .image => |t| t.source,
            .audio => |t| t.source,
            .file => |t| t.source,
        };
        try db.queries.insert_blob_ref.exec(.{ .session_id = session_id, .hash = blob.hash.raw, .bytes = blob.bytes });
    }
}

/// List the blobs one session names. The caller reads this before it deletes the session rows.
pub fn refsOf(db: *Database, arena: std.mem.Allocator, session_id: [16]u8) ![]const Hash {
    var rows = try db.queries.blob_refs_of_session.rows(.{ .session_id = session_id });
    defer rows.deinit();
    var out: std.ArrayList(Hash) = .empty;
    while (try rows.next(arena)) |owned| try out.append(arena, .bytes(owned.value.hash));
    return out.items;
}

/// Report whether any session still names the blob.
pub fn referenced(db: *Database, arena: std.mem.Allocator, hash: Hash) !bool {
    return (try db.queries.blob_referenced.maybeOne(arena, .{ .hash = hash.raw })) != null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

pub const png_1x1 = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++ "\x00\x00\x00\x0dIDAT\x78\x9c\x63\x64\x60\xf8\xcf\x00\x00\x02\x87\x01\x80" ++ "\x00\x00\x00\x00IEND\xaeB`\x82";

const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8,
    store: Store,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const root = self.buf[0..try self.tmp.dir.realPath(testing.io, &self.buf)];
        self.arena = .init(testing.allocator);
        self.store = .{ .dir = try std.fs.path.join(self.arena.allocator(), &.{ root, "blobs" }) };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn file(self: *Fixture, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        const root = self.buf[0..try self.tmp.dir.realPath(testing.io, &self.buf)];
        return std.fs.path.join(self.arena.allocator(), &.{ root, name });
    }
};

test "put copies an image by hash, describes it, and repeats as a no-op" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try f.file("shot.png", png_1x1);

    const blob = try f.store.put(testing.io, a, path);
    try testing.expectEqualStrings("image/png", blob.mime);
    try testing.expectEqual(@as(u64, png_1x1.len), blob.bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png_1x1, &digest, .{});
    try testing.expectEqualSlices(u8, &digest, &blob.hash.raw);
    try testing.expectEqualStrings(png_1x1, try f.store.read(testing.io, a, blob.hash));

    const again = try f.store.put(testing.io, a, path);
    try testing.expectEqualSlices(u8, &blob.hash.raw, &again.hash.raw);
    var count: usize = 0;
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, f.store.dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count); // No temp file and no second copy remain.

    try f.store.unlink(testing.io, a, blob.hash);
    try testing.expectError(error.BlobMissing, f.store.read(testing.io, a, blob.hash));
    try f.store.unlink(testing.io, a, blob.hash); // A second unlink of an absent file is valid.
}

test "put names every image type by its magic bytes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const webp = "RIFF\x24\x00\x00\x00WEBPVP8 " ++ "\x00" ** 16;
    inline for (.{
        .{ "a.jpg", "\xff\xd8\xff\xe0" ++ "\x00" ** 8, "image/jpeg" },
        .{ "a.gif", "GIF89a" ++ "\x00" ** 8, "image/gif" },
        .{ "a.webp", webp, "image/webp" },
    }) |case| {
        const blob = try f.store.put(testing.io, a, try f.file(case[0], case[1]));
        try testing.expectEqualStrings(case[2], blob.mime);
    }
}

test "put refuses what the store must never hold" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectError(error.BlobPathNotAbsolute, f.store.put(testing.io, a, "shot.png"));
    try testing.expectError(error.BlobUnreadable, f.store.put(testing.io, a, try std.fs.path.join(a, &.{ f.store.dir, "..", "absent.png" })));
    try testing.expectError(error.BlobNotRegularFile, f.store.put(testing.io, a, std.fs.path.dirname(f.store.dir).?));
    try testing.expectError(error.BlobEmpty, f.store.put(testing.io, a, try f.file("empty.png", "")));
    try testing.expectError(error.BlobUnsupportedType, f.store.put(testing.io, a, try f.file("doc.pdf", "%PDF-1.7\n")));
    try testing.expectError(error.BlobUnsupportedType, f.store.put(testing.io, a, try f.file("fake.png", "not a png at all")));
    const big = try a.alloc(u8, max_bytes + 1);
    @memcpy(big[0..8], "\x89PNG\r\n\x1a\n");
    try testing.expectError(error.BlobTooLarge, f.store.put(testing.io, a, try f.file("big.png", big)));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testing.io, f.store.dir, .{})); // Nothing was written.
}

test "admit accepts only refs that match the stored bytes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const blob = try f.store.put(testing.io, a, try f.file("shot.png", png_1x1));
    const text: proto.content.ContentPart = .{ .text = .{ .text = "look" } };
    try f.store.admit(testing.io, a, &.{ text, .{ .image = .{ .source = blob } } });
    try f.store.admit(testing.io, a, &.{});

    var wrong_size = blob;
    wrong_size.bytes += 1;
    try testing.expectError(error.BlobMismatch, f.store.admit(testing.io, a, &.{.{ .image = .{ .source = wrong_size } }}));
    var wrong_mime = blob;
    wrong_mime.mime = "image/jpeg";
    try testing.expectError(error.BlobMismatch, f.store.admit(testing.io, a, &.{.{ .image = .{ .source = wrong_mime } }}));
    var absent = blob;
    absent.hash = .bytes(@splat(0));
    try testing.expectError(error.BlobMissing, f.store.admit(testing.io, a, &.{.{ .image = .{ .source = absent } }}));
    try testing.expectError(error.BlobUnsupportedPart, f.store.admit(testing.io, a, &.{.{ .file = .{ .source = blob } }}));
    try testing.expectError(error.BlobUnsupportedPart, f.store.admit(testing.io, a, &.{.{ .audio = .{ .source = blob, .format = "mp3" } }}));

    const image: proto.content.ContentPart = .{ .image = .{ .source = blob } };
    try f.store.admit(testing.io, a, &(.{image} ** max_images_per_input));
    try testing.expectError(error.BlobTooManyImages, f.store.admit(testing.io, a, &(.{image} ** (max_images_per_input + 1))));
}

test "refs count per session and answer whether a blob is still named" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one: [16]u8 = @splat(1);
    const two: [16]u8 = @splat(2);
    try @import("session.zig").seedSession(&db, one);
    try @import("session.zig").seedSession(&db, two);
    const shared: MediaBlob = .{ .hash = .bytes(@splat(0xaa)), .mime = "image/png", .bytes = 1 };
    const only: MediaBlob = .{ .hash = .bytes(@splat(0xbb)), .mime = "image/png", .bytes = 1 };

    var tx = try db.begin();
    defer tx.deinit();
    try recordRefs(&db, one, &.{ .{ .image = .{ .source = shared } }, .{ .image = .{ .source = only } }, .{ .image = .{ .source = only } } });
    try recordRefs(&db, two, &.{.{ .image = .{ .source = shared } }});
    try tx.commit();

    const refs = try refsOf(&db, a, one);
    try testing.expectEqual(@as(usize, 2), refs.len);
    // The size travels into the row for a later budget pass.
    const size_row = (try db.conn.row("SELECT bytes FROM blob_refs WHERE session_id = ?1 AND hash = ?2", .{ zqlite.blob(&one), zqlite.blob(&shared.hash.raw) })).?;
    defer size_row.deinit();
    try testing.expectEqual(@as(u64, 1), @as(u64, @intCast(size_row.int(0))));
    var removal = try db.begin();
    defer removal.deinit();
    try @import("session.zig").remove(&db, one);
    try removal.commit();
    try testing.expect(try referenced(&db, a, shared.hash));
    try testing.expect(!try referenced(&db, a, only.hash));
}
