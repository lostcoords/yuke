//! Persist each enrolled principal as one JSON file, so its credential and key commit together.

const std = @import("std");
const builtin = @import("builtin");

const X25519 = std.crypto.dh.X25519;

/// The raw private key length, and the length of its base64 form.
pub const secret_length = X25519.secret_length;
pub const key_b64_length = std.base64.standard.Encoder.calcSize(secret_length);

/// Bound one metadata file. A credential, a key, and three identifiers stay far below this.
const max_meta_bytes = 16 * 1024;

/// The current metadata schema. A file of another version is malformed.
pub const schema_version = 1;

/// Name one enrolled principal. It selects the file.
pub const Principal = enum {
    device,
    session,

    pub fn file(self: Principal) []const u8 {
        return switch (self) {
            .device => "credentials.json",
            .session => "session.json",
        };
    }
};

pub const Error = error{
    /// The stored key is not one X25519 private key.
    KeyInvalid,
    /// The metadata is malformed, or of an unknown schema.
    Malformed,
    /// The document does not fit the bounded write buffer.
    MetaTooLarge,
};

/// The device principal. It identifies the daemon to the relay.
pub const Device = struct {
    device_id: []const u8,
    credential: []const u8,
    relay_url: []const u8,
    /// The base64 X25519 private key. The caller keeps it secret.
    identity_key: []const u8,
    schema_version: u32,
};

/// The client principal. A `token` session presents only a credential, so it holds no key.
pub const Session = struct {
    session_id: []const u8,
    credential: []const u8,
    relay_url: []const u8,
    kind: []const u8,
    /// The base64 X25519 private key. A `token` session leaves it empty.
    identity_key: []const u8 = "",
    schema_version: u32,
};

/// Return a fresh X25519 private key, and reject a seed that has no valid public key.
pub fn generateSecret(io: std.Io) ![secret_length]u8 {
    var secret: [secret_length]u8 = undefined;
    try io.randomSecure(&secret);
    // Reject the rare seed that has no valid public key. The caller then sees a plain error.
    _ = X25519.recoverPublicKey(secret) catch return error.KeyInvalid;
    return secret;
}

/// Return the base64 public key of `secret`. The control plane pins this value.
pub fn publicKeyBase64(secret: [secret_length]u8) Error![key_b64_length]u8 {
    const public = X25519.recoverPublicKey(secret) catch return error.KeyInvalid;
    return encode(&public);
}

/// Return the base64 private key of `secret`. The file holds this value.
pub fn encodeSecret(secret: [secret_length]u8) [key_b64_length]u8 {
    return encode(&secret);
}

/// Decode a stored base64 private key. The value is peer input, so a bad value gives an error.
pub fn decodeSecret(text: []const u8) Error![secret_length]u8 {
    if (text.len != key_b64_length) return error.KeyInvalid;
    var out: [secret_length]u8 = undefined;
    std.base64.standard.Decoder.decode(&out, text) catch return error.KeyInvalid;
    return out;
}

fn encode(raw: *const [secret_length]u8) [key_b64_length]u8 {
    var out: [key_b64_length]u8 = undefined;
    const written = std.base64.standard.Encoder.encode(&out, raw);
    std.debug.assert(written.len == out.len); // The encoder fills a buffer of its own size.
    return out;
}

/// Open the data directory and create it when it is absent. A new POSIX directory gets mode 0700.
pub fn openDataDir(io: std.Io, path: []const u8) !std.Io.Dir {
    std.debug.assert(path.len != 0);

    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = permissions });
}

/// What one principal holds on disk. A `token` session keeps no key.
pub const Stored = struct {
    secret: ?[secret_length]u8,
};

/// Read `principal`. An absent or malformed principal gives null, so a later login repairs it.
pub fn read(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, comptime T: type, principal: Principal) ?Stored {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const meta = (readMeta(arena.allocator(), io, dir, T, principal) catch return null) orelse return null;
    if (meta.identity_key.len == 0) return .{ .secret = null };
    return .{ .secret = decodeSecret(meta.identity_key) catch return null };
}

/// Write `principal` metadata as one atomic replacement, so the credential and key commit together.
pub fn writeMeta(io: std.Io, dir: std.Io.Dir, principal: Principal, value: anytype) !void {
    // The fixed buffer bounds one document, so an oversized value fails instead of growing.
    var buf: [max_meta_bytes]u8 = undefined;
    var json: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(value, .{}, &json) catch return error.MetaTooLarge;
    try writePrivateFile(io, dir, principal.file(), json.buffered());
}

/// Read the metadata of `principal`. An absent file gives null. The result borrows `arena`.
pub fn readMeta(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, comptime T: type, principal: Principal) !?T {
    const bytes = dir.readFileAlloc(io, principal.file(), arena, .limited(max_meta_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return error.Malformed,
        else => return err,
    };

    const out = std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true }) catch return error.Malformed;
    if (out.schema_version != schema_version) return error.Malformed;
    if (out.credential.len == 0 or out.relay_url.len == 0) return error.Malformed;
    // A present key must be one X25519 private key. Each principal decides whether it needs one.
    if (out.identity_key.len != 0) _ = try decodeSecret(out.identity_key);
    if (T == Device and out.identity_key.len == 0) return error.Malformed;
    if (T == Session) {
        if (std.mem.eql(u8, out.kind, "cli") and out.identity_key.len == 0) return error.Malformed;
        if (std.mem.eql(u8, out.kind, "token") and out.identity_key.len != 0) return error.Malformed;
        if (!std.mem.eql(u8, out.kind, "cli") and !std.mem.eql(u8, out.kind, "token")) return error.Malformed;
    }
    return out;
}

/// Write a private temporary file beside the target, then replace the target in one step.
fn writePrivateFile(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    std.debug.assert(name.len != 0);
    std.debug.assert(data.len != 0);

    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);

    var atomic = try dir.createFileAtomic(io, name, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);

    // The temporary file decides the final mode, so set it before the replacement.
    if (builtin.os.tag != .windows) try atomic.file.setPermissions(io, permissions);

    var buf: [1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();

    // `replace` renames without a flush, so sync first to put the contents on stable storage.
    try atomic.file.sync(io);
    try atomic.replace(io);
}

const testing = std.testing;

test "a key round-trips through its stored base64 form" {
    const io = testing.io;
    const secret = try generateSecret(io);
    const stored = encodeSecret(secret);
    try testing.expectEqual(@as(usize, 44), stored.len);

    const reloaded = try decodeSecret(&stored);
    try testing.expectEqualSlices(u8, &secret, &reloaded);

    // The public key survives the round trip, because X25519 clamps the scalar at use.
    const before = try publicKeyBase64(secret);
    const after = try publicKeyBase64(reloaded);
    try testing.expectEqualStrings(&before, &after);
}

test "decodeSecret rejects a wrong length and a bad alphabet" {
    try testing.expectError(error.KeyInvalid, decodeSecret("short"));
    try testing.expectError(error.KeyInvalid, decodeSecret("!" ** 44));
}

test "two generated keys differ" {
    const io = testing.io;
    const a = try generateSecret(io);
    const b = try generateSecret(io);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "an absent principal reads as null" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expect(read(testing.allocator, io, tmp.dir, Device, .device) == null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try readMeta(arena.allocator(), io, tmp.dir, Device, .device)) == null);
}

test "a written device round-trips with its key" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const secret = try generateSecret(io);
    const stored = encodeSecret(secret);
    try writeMeta(io, tmp.dir, .device, Device{
        .device_id = "d1",
        .credential = "yk_dev_abc",
        .relay_url = "wss://relay.example",
        .identity_key = &stored,
        .schema_version = schema_version,
    });

    try testing.expect(read(testing.allocator, io, tmp.dir, Device, .device) != null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const loaded = (try readMeta(arena.allocator(), io, tmp.dir, Device, .device)).?;
    try testing.expectEqualStrings("d1", loaded.device_id);
    try testing.expectEqualStrings("yk_dev_abc", loaded.credential);

    const reused = read(testing.allocator, io, tmp.dir, Device, .device).?.secret.?;
    try testing.expectEqualSlices(u8, &secret, &reused);
}

test "a bad schema and a bad key are rejected" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try writePrivateFile(io, tmp.dir, Principal.device.file(),
        \\{"schema_version":9,"device_id":"d","credential":"c","relay_url":"r"}
    );
    try testing.expectError(error.Malformed, readMeta(arena.allocator(), io, tmp.dir, Device, .device));
    try testing.expect(read(testing.allocator, io, tmp.dir, Device, .device) == null);

    try writePrivateFile(io, tmp.dir, Principal.device.file(),
        \\{"schema_version":1,"device_id":"d","credential":"c","relay_url":"r","identity_key":"nope"}
    );
    try testing.expectError(error.KeyInvalid, readMeta(arena.allocator(), io, tmp.dir, Device, .device));
}

test "a token session keeps no key and still reads back" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeMeta(io, tmp.dir, .session, Session{
        .session_id = "s1",
        .credential = "yk_sess_abc",
        .relay_url = "wss://relay.example",
        .kind = "token",
        .schema_version = schema_version,
    });

    try testing.expect(read(testing.allocator, io, tmp.dir, Session, .session).?.secret == null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const loaded = (try readMeta(arena.allocator(), io, tmp.dir, Session, .session)).?;
    try testing.expectEqualStrings("token", loaded.kind);
}
