//! Load the `yuked.json` daemon config. It seeds a new session's system prompt and lists the small models.
//! The file holds no secrets. A missing file returns built-in defaults. A `session.create` field overrides a default.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Limit the file size.
const max_file_bytes = 256 << 10;

/// The daemon defaults. Each string borrows the `Loaded` arena.
pub const Defaults = struct {
    small_model: ?[]const []const u8 = null, // The small, fast models serve auxiliary calls, such as a session title.
    system_prompt: ?[]const u8 = null,
};

// The parser ignores unknown fields for forward compatibility. It rejects duplicate keys.
const FileDoc = struct {
    version: u32,
    small_model: ?[]const []const u8 = null,
    system_prompt: ?[]const u8 = null,
};

/// The arena owns every string. The daemon holds one `Loaded` for its lifetime.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    defaults: Defaults = .{},

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Read `path` and resolve it. A missing file returns built-in defaults. An invalid file returns an error.
/// `path` must be absolute. The daemon builds it from the config directory.
pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Loaded {
    const raw = readFile(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => return empty(gpa),
        else => |e| return e,
    };
    defer gpa.free(raw);
    return loadBytes(gpa, raw);
}

/// Parse one document. The caller owns `bytes`. `alloc_always` copies each value into the arena.
pub fn loadBytes(gpa: Allocator, bytes: []const u8) !Loaded {
    if (bytes.len > max_file_bytes) return error.FileTooLarge;

    var out: Loaded = empty(gpa);
    errdefer out.deinit();
    const arena = out.arena.allocator();

    const doc = try std.json.parseFromSliceLeaky(FileDoc, arena, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    });

    if (doc.version != 1) return error.BadVersion;
    // The daemon does not validate a model selector. A client validates it before it sends the request.
    out.defaults = .{ .small_model = doc.small_model, .system_prompt = doc.system_prompt };
    return out;
}

fn empty(gpa: Allocator) Loaded {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

/// Do not follow symlinks. Reject non-regular files. Read the file into a size-limited buffer.
fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind != .file) return error.NotRegularFile;
    if (st.size > max_file_bytes) return error.FileTooLarge;

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.readAlloc(gpa, @intCast(st.size));
}

const testing = std.testing;

test "loadBytes reads the defaults" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1,"small_model":["prov/mini","prov/mini2"],"system_prompt":"be brief"}
    );
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.defaults.small_model.?.len);
    try testing.expectEqualStrings("prov/mini", loaded.defaults.small_model.?[0]);
    try testing.expectEqualStrings("prov/mini2", loaded.defaults.small_model.?[1]);
    try testing.expectEqualStrings("be brief", loaded.defaults.system_prompt.?);
}

test "loadBytes copies values out of the input" {
    const bytes = try testing.allocator.dupe(u8, "{\"version\":1,\"small_model\":[\"prov/mini\"],\"system_prompt\":\"be brief\"}");
    defer testing.allocator.free(bytes);
    var loaded = try loadBytes(testing.allocator, bytes);
    defer loaded.deinit();
    @memset(bytes, 'x');
    try testing.expectEqualStrings("prov/mini", loaded.defaults.small_model.?[0]);
    try testing.expectEqualStrings("be brief", loaded.defaults.system_prompt.?);
}

test "loadBytes accepts a minimal document" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1}
    );
    defer loaded.deinit();
    try testing.expect(loaded.defaults.small_model == null);
    try testing.expect(loaded.defaults.system_prompt == null);
}

test "loadBytes rejects a bad version" {
    try testing.expectError(error.BadVersion, loadBytes(testing.allocator,
        \\{"version":2}
    ));
}

test "loadBytes ignores an unknown field" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1,"system_prompt":"go","nope":true}
    );
    defer loaded.deinit();
    try testing.expectEqualStrings("go", loaded.defaults.system_prompt.?);
}

test "loadBytes rejects a duplicate field" {
    try testing.expectError(error.DuplicateField, loadBytes(testing.allocator,
        \\{"version":1,"version":1}
    ));
}
